package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

// 测试里扮演 napboxd 那一头
type muxPeer struct {
	t      *testing.T
	conn   net.Conn
	lock   sync.Mutex
	frames chan peerFrame
}

type peerFrame struct {
	id      uint32
	kind    byte
	payload []byte
}

func startMux(t *testing.T, dial func(string) (net.Conn, error)) *muxPeer {
	host, guest := net.Pipe()
	go serveMux(guest, dial)
	t.Cleanup(func() { host.Close() })
	peer := &muxPeer{t: t, conn: host, frames: make(chan peerFrame, 100000)}
	go func() {
		header := make([]byte, frameHeaderSize)
		for {
			if _, err := io.ReadFull(host, header); err != nil {
				close(peer.frames)
				return
			}
			payload := make([]byte, binary.BigEndian.Uint32(header[5:]))
			if _, err := io.ReadFull(host, payload); err != nil {
				close(peer.frames)
				return
			}
			peer.frames <- peerFrame{binary.BigEndian.Uint32(header), header[4], payload}
		}
	}()
	return peer
}

func (p *muxPeer) send(id uint32, kind byte, payload []byte) {
	frame := make([]byte, frameHeaderSize+len(payload))
	binary.BigEndian.PutUint32(frame, id)
	frame[4] = kind
	binary.BigEndian.PutUint32(frame[5:], uint32(len(payload)))
	copy(frame[frameHeaderSize:], payload)
	p.lock.Lock()
	defer p.lock.Unlock()
	if _, err := p.conn.Write(frame); err != nil {
		p.t.Error(err)
	}
}

func (p *muxPeer) next() peerFrame {
	select {
	case frame, ok := <-p.frames:
		if !ok {
			p.t.Fatal("连接断了")
		}
		return frame
	case <-time.After(5 * time.Second):
		p.t.Fatal("等帧超时")
	}
	return peerFrame{}
}

func window(n int) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, uint32(n))
	return b
}

func echoServer(t *testing.T) string {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				io.Copy(c, c)
				c.(*net.TCPConn).CloseWrite()
				c.Close()
			}()
		}
	}()
	return listener.Addr().String()
}

func tcpDial(target string) (net.Conn, error) { return net.Dial("tcp", target) }

func TestEchoAndHalfClose(t *testing.T) {
	peer := startMux(t, tcpDial)
	peer.send(1, frameOpen, []byte(echoServer(t)))
	peer.send(1, frameData, []byte("hello"))
	for {
		f := peer.next()
		if f.kind == frameData {
			if string(f.payload) != "hello" {
				t.Fatalf("回显不对：%q", f.payload)
			}
			break
		}
		if f.kind != frameWindow {
			t.Fatalf("不该是 %d", f.kind)
		}
	}
	// 半关闭传到服务，服务写完后这边依次收到 fin 和 reset
	peer.send(1, frameFin, nil)
	var kinds []byte
	for len(kinds) == 0 || kinds[len(kinds)-1] != frameReset {
		kinds = append(kinds, peer.next().kind)
	}
	if !bytes.Contains(kinds, []byte{frameFin}) {
		t.Fatalf("没收到 fin：%v", kinds)
	}
}

func TestDialFailureResets(t *testing.T) {
	peer := startMux(t, tcpDial)
	peer.send(7, frameOpen, []byte("127.0.0.1:1"))
	if f := peer.next(); f.id != 7 || f.kind != frameReset {
		t.Fatalf("应该 reset：%+v", f)
	}
}

// 服务一直在输出：额度用完就停，还了额度才继续，内容不错不丢
func TestSendStopsWithoutCredit(t *testing.T) {
	data := make([]byte, 3*initialStreamSend)
	rand.Read(data)
	dial := func(string) (net.Conn, error) {
		client, server := net.Pipe()
		go func() {
			server.Write(data)
			server.Close()
		}()
		return client, nil
	}
	peer := startMux(t, dial)
	peer.send(1, frameOpen, []byte("x"))
	var got []byte
	for len(got) < initialStreamSend {
		f := peer.next()
		if f.kind != frameData {
			t.Fatalf("不该是 %d", f.kind)
		}
		got = append(got, f.payload...)
	}
	if len(got) != initialStreamSend {
		t.Fatalf("超出额度：%d", len(got))
	}
	select {
	case f := <-peer.frames:
		t.Fatalf("没有额度还在发：%d 字节", len(f.payload))
	case <-time.After(200 * time.Millisecond):
	}
	peer.send(1, frameWindow, window(len(data)))
	for {
		f := peer.next()
		if f.kind == frameData {
			got = append(got, f.payload...)
		} else if f.kind == frameFin {
			break
		}
	}
	if !bytes.Equal(got, data) {
		t.Fatal("内容不对")
	}
}

// 一个服务不读，不影响同一条连接上的其他流
func TestStuckServiceDoesNotBlockOthers(t *testing.T) {
	echo := echoServer(t)
	stuck, stuckServer := net.Pipe() // 对面不读
	defer stuckServer.Close()
	dial := func(target string) (net.Conn, error) {
		if target == "stuck" {
			return stuck, nil
		}
		return tcpDial(target)
	}
	peer := startMux(t, dial)
	peer.send(1, frameOpen, []byte("stuck"))
	for i := 0; i < 10; i++ {
		peer.send(1, frameData, make([]byte, maxFramePayload))
	}
	peer.send(2, frameOpen, []byte(echo))
	peer.send(2, frameData, []byte("still works"))
	for {
		f := peer.next()
		if f.id == 2 && f.kind == frameData {
			if string(f.payload) != "still works" {
				t.Fatalf("回显不对：%q", f.payload)
			}
			return
		}
	}
}

// 这边 reset：服务的连接被关掉，不留 goroutine 卡着
func TestResetClosesService(t *testing.T) {
	closed := make(chan struct{})
	dial := func(string) (net.Conn, error) {
		client, server := net.Pipe()
		go func() {
			io.Copy(io.Discard, server)
			close(closed)
		}()
		return client, nil
	}
	peer := startMux(t, dial)
	peer.send(1, frameOpen, []byte("x"))
	time.Sleep(50 * time.Millisecond)
	peer.send(1, frameReset, nil)
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("服务的连接没关")
	}
}
