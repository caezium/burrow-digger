package main

import (
	"encoding/json"
	"testing"
)

// The progress event is one NDJSON line the GUI/agent reads live during a scan,
// mirroring `status --watch`'s stream contract (one JSON object per line).
func TestProgressEventIsNDJSON(t *testing.T) {
	line := progressEvent(3, 2, 4096, "/tmp/x")
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		t.Fatalf("progress event must be valid JSON: %v (%s)", err, line)
	}
	if m["type"] != "progress" {
		t.Errorf("type = %v, want progress", m["type"])
	}
	if m["files"] != float64(3) || m["dirs"] != float64(2) || m["bytes"] != float64(4096) {
		t.Errorf("counters = %v", m)
	}
	if m["path"] != "/tmp/x" {
		t.Errorf("path = %v", m["path"])
	}
}

// The final line of a --progress stream is a `type:"result"` event carrying the
// full analysis as `data`, so a consumer reads progress lines until it arrives.
func TestResultEventWrapsData(t *testing.T) {
	line, err := resultEvent(map[string]any{"total_files": 7})
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		t.Fatalf("result event must be valid JSON: %v", err)
	}
	if m["type"] != "result" {
		t.Errorf("type = %v, want result", m["type"])
	}
	data, _ := m["data"].(map[string]any)
	if data["total_files"] != float64(7) {
		t.Errorf("analysis not embedded under data: %v", m)
	}
}
