package main

import "encoding/json"

// progressEvent formats one NDJSON scan-progress line for `analyze --json --progress`,
// mirroring `status --watch`'s contract: a GUI/agent renders the treemap filling in
// live instead of blocking on the whole tree. `type:"progress"` during the scan.
func progressEvent(files, dirs, bytes int64, path string) []byte {
	b, _ := json.Marshal(map[string]any{
		"type":  "progress",
		"files": files,
		"dirs":  dirs,
		"bytes": bytes,
		"path":  path,
	})
	return b
}

// resultEvent wraps the final analysis as the terminating NDJSON line of a
// `--progress` stream: a consumer reads progress lines until this `type:"result"`.
func resultEvent(data any) ([]byte, error) {
	return json.Marshal(map[string]any{"type": "result", "data": data})
}
