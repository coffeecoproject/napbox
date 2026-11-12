//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestChmodKeepsModificationTime(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "a")
	if err := os.WriteFile(file, []byte("x"), 0o640); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(file)
	mode := uint32(0o640)
	if r := applyNotifications([]notifyItem{{Path: file, Mode: &mode}}); r.Failed != 0 {
		t.Fatal(r)
	}
	after, _ := os.Stat(file)
	if !after.ModTime().Equal(before.ModTime()) || after.Mode() != before.Mode() {
		t.Fatalf("改了文件：%v %v -> %v %v", before.ModTime(), before.Mode(), after.ModTime(), after.Mode())
	}
}

func TestRootSignalLeavesNothing(t *testing.T) {
	dir := t.TempDir()
	if r := applyNotifications([]notifyItem{{Path: dir}}); r.Failed != 0 {
		t.Fatal(r)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Fatalf("留下了 %v", entries)
	}
}

func TestVanishedFileIsNotAFailure(t *testing.T) {
	mode := uint32(0o644)
	if r := applyNotifications([]notifyItem{{Path: filepath.Join(t.TempDir(), "gone"), Mode: &mode}}); r.Failed != 0 {
		t.Fatal(r)
	}
}

func TestRealFailureIsCounted(t *testing.T) {
	mode := uint32(0o644)
	file := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	r := applyNotifications([]notifyItem{{Path: filepath.Join(file, "under-a-file"), Mode: &mode}})
	if r.Failed != 1 || r.First == "" {
		t.Fatal(r)
	}
}
