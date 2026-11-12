package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
)

// 一条 vsock 上复用所有转发的连接。一个连接一条 vsock 不行：同时一两百条时
// Apple 的虚拟化进程会在 vsock 设备里崩溃，整个环境没了（2026-11-08 实测）。
//
// 帧：4 字节流 id、1 字节类型、4 字节内容长度（都是大端），然后是内容。协议的另一头在 napboxd 的 RelayMux.swift。
// 流由 napboxd 打开。每个方向有发送额度：对方写出去多少就还多少（frameWindow），
// 一个读得慢的连接只会等自己的额度，不会堵住同一条 vsock 上的其他连接。
const (
	frameOpen   byte = 1 // 内容是目标地址 ip:端口
	frameData   byte = 2
	frameWindow byte = 3 // 内容是 4 字节，还回来的额度
	frameFin    byte = 4 // 发送方向结束（半关闭）
	frameReset  byte = 5 // 整个流结束

	frameHeaderSize   = 9
	maxFramePayload   = 64 * 1024
	initialStreamSend = 1024 * 1024
	// 攒够这么多才还额度：每收到一点就还的话，一次小查询要多跑两趟，延迟明显变大。两头一样（RelayMux.swift）
	windowBatch = initialStreamSend / 4
)

type mux struct {
	writeLock sync.Mutex
	writer    io.Writer
	frame     []byte // 整帧一次写出，不分成帧头和内容两次：每多一次写，那边就多醒一次
	dial      func(target string) (net.Conn, error)

	lock    sync.Mutex
	streams map[uint32]*muxStream
}

type halfCloser interface {
	CloseWrite() error
}

type muxStream struct {
	id      uint32
	mux     *mux
	service net.Conn

	lock   sync.Mutex
	wake   *sync.Cond
	credit int
	reset  bool
	// 收到的数据排队，由单独的 goroutine 写给服务：服务不读时不能堵住 vsock 的读循环。长度受对方的额度限制
	incoming [][]byte
	finished bool // 对方不再发了
}

func serveMux(connection io.ReadWriter, dial func(string) (net.Conn, error)) error {
	m := &mux{writer: connection, dial: dial, streams: map[uint32]*muxStream{}}
	defer m.resetAll()
	reader := bufio.NewReaderSize(connection, maxFramePayload+frameHeaderSize)
	header := make([]byte, frameHeaderSize)
	for {
		if _, err := io.ReadFull(reader, header); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		id := binary.BigEndian.Uint32(header)
		kind := header[4]
		length := binary.BigEndian.Uint32(header[5:])
		if length > maxFramePayload {
			return errors.New("帧太长")
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(reader, payload); err != nil {
			return err
		}
		m.handle(id, kind, payload)
	}
}

func (m *mux) handle(id uint32, kind byte, payload []byte) {
	if kind == frameOpen {
		stream := &muxStream{id: id, mux: m, credit: initialStreamSend}
		stream.wake = sync.NewCond(&stream.lock)
		m.lock.Lock()
		m.streams[id] = stream
		m.lock.Unlock()
		go stream.run(string(payload))
		return
	}
	m.lock.Lock()
	stream := m.streams[id]
	m.lock.Unlock()
	if stream == nil {
		return // 这边已经结束了，对方发出 reset 之前路上的帧
	}
	stream.lock.Lock()
	defer stream.lock.Unlock()
	switch kind {
	case frameData:
		stream.incoming = append(stream.incoming, payload)
	case frameWindow:
		if len(payload) == 4 {
			stream.credit += int(binary.BigEndian.Uint32(payload))
		}
	case frameFin:
		stream.finished = true
	case frameReset:
		stream.reset = true
		if stream.service != nil {
			stream.service.Close()
		}
	}
	stream.wake.Broadcast()
}

func (m *mux) send(id uint32, kind byte, payload []byte) error {
	m.writeLock.Lock()
	defer m.writeLock.Unlock()
	frame := binary.BigEndian.AppendUint32(m.frame[:0], id)
	frame = append(frame, kind)
	frame = binary.BigEndian.AppendUint32(frame, uint32(len(payload)))
	frame = append(frame, payload...)
	m.frame = frame
	_, err := m.writer.Write(frame)
	return err
}

func (m *mux) resetAll() {
	m.lock.Lock()
	streams := make([]*muxStream, 0, len(m.streams))
	for _, stream := range m.streams {
		streams = append(streams, stream)
	}
	m.lock.Unlock()
	for _, stream := range streams {
		stream.lock.Lock()
		stream.reset = true
		if stream.service != nil {
			stream.service.Close()
		}
		stream.wake.Broadcast()
		stream.lock.Unlock()
	}
}

func (s *muxStream) run(target string) {
	defer func() {
		s.mux.lock.Lock()
		delete(s.mux.streams, s.id)
		s.mux.lock.Unlock()
		s.mux.send(s.id, frameReset, nil)
	}()
	service, err := s.mux.dial(target)
	if err != nil {
		return
	}
	defer service.Close()
	s.lock.Lock()
	if s.reset {
		s.lock.Unlock()
		return
	}
	s.service = service
	s.lock.Unlock()

	var finished sync.WaitGroup
	finished.Add(2)
	go func() {
		defer finished.Done()
		s.toService()
	}()
	go func() {
		defer finished.Done()
		s.fromService()
	}()
	finished.Wait()
}

// 收到的数据写给服务，写完攒着还额度
func (s *muxStream) toService() {
	owed := 0
	for {
		s.lock.Lock()
		for len(s.incoming) == 0 && !s.finished && !s.reset {
			s.wake.Wait()
		}
		if s.reset {
			s.lock.Unlock()
			return
		}
		if len(s.incoming) == 0 {
			s.lock.Unlock()
			if closer, ok := s.service.(halfCloser); ok {
				closer.CloseWrite()
			}
			return
		}
		data := s.incoming[0]
		s.incoming = s.incoming[1:]
		s.lock.Unlock()
		if _, err := s.service.Write(data); err != nil {
			s.service.Close()
			s.markReset()
			return
		}
		owed += len(data)
		if owed >= windowBatch {
			s.mux.send(s.id, frameWindow, binary.BigEndian.AppendUint32(nil, uint32(owed)))
			owed = 0
		}
	}
}

// 服务的输出发给对方，没有额度时等
func (s *muxStream) fromService() {
	// 从小开始，读满了才加大：大多数连接是空闲的，上千条时不能每条都占 64KB（网络小容器有内存上限）
	buffer := make([]byte, 4*1024)
	for {
		s.lock.Lock()
		for s.credit <= 0 && !s.reset {
			s.wake.Wait()
		}
		credit := s.credit
		reset := s.reset
		s.lock.Unlock()
		if reset {
			return
		}
		size := len(buffer)
		if credit < size {
			size = credit
		}
		n, err := s.service.Read(buffer[:size])
		if n > 0 {
			s.lock.Lock()
			s.credit -= n
			s.lock.Unlock()
			if s.mux.send(s.id, frameData, buffer[:n]) != nil {
				s.service.Close()
				s.markReset()
				return
			}
			if n == len(buffer) && len(buffer) < maxFramePayload {
				buffer = make([]byte, 2*len(buffer))
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				s.mux.send(s.id, frameFin, nil)
			} else {
				s.service.Close()
				s.markReset()
			}
			return
		}
	}
}

// 一个方向出错了：连接已经没法用，叫醒另一个方向一起结束
func (s *muxStream) markReset() {
	s.lock.Lock()
	s.reset = true
	s.wake.Broadcast()
	s.lock.Unlock()
}
