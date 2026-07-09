//go:build darwin

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The progress-aware scan returns the correct result AND every streamed line is a
// valid `type:"progress"` NDJSON event. Progress is time-based (best-effort), so we
// assert the result is right and any emitted lines parse — not a fixed count.
func TestDirectoryScanWithProgressStreamsValidNDJSON(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"a.txt", "b.txt", "c.txt"} {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("xxxx"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	var buf bytes.Buffer
	out := performDirectoryScanForJSONWithProgress(dir, &buf, time.Millisecond)

	if out.Path != dir {
		t.Errorf("path = %q, want %q", out.Path, dir)
	}
	if out.TotalFiles < 3 {
		t.Errorf("total_files = %d, want >= 3", out.TotalFiles)
	}
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatalf("progress line is not valid JSON: %v (%s)", err, sc.Bytes())
		}
		if m["type"] != "progress" {
			t.Errorf("streamed line type = %v, want progress", m["type"])
		}
	}
}
