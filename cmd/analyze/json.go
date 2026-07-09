//go:build darwin

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type jsonOutput struct {
	Path       string          `json:"path"`
	Overview   bool            `json:"overview"`
	Entries    []jsonEntry     `json:"entries"`
	LargeFiles []jsonFileEntry `json:"large_files,omitempty"`
	TotalSize  int64           `json:"total_size"`
	TotalFiles int64           `json:"total_files,omitempty"`
}

type jsonEntry struct {
	Name       string `json:"name"`
	Path       string `json:"path"`
	Size       int64  `json:"size"`
	IsDir      bool   `json:"is_dir"`
	Insight    bool   `json:"insight,omitempty"`
	Cleanable  bool   `json:"cleanable,omitempty"`
	LastAccess string `json:"last_access,omitempty"`
}

type jsonFileEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Size int64  `json:"size"`
}

func runJSONMode(path string, isOverview bool) {
	// --progress: stream NDJSON scan-progress events on stdout during the scan,
	// then a terminating `result` event — so a GUI renders the treemap live.
	// (Overview mode keeps the plain batch output.)
	if *progressMode && !isOverview {
		result := performDirectoryScanForJSONWithProgress(path, os.Stdout, 200*time.Millisecond)
		line, err := resultEvent(result)
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to encode result: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(string(line))
		return
	}

	result := performScanForJSON(path, isOverview)
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintf(os.Stderr, "failed to encode JSON: %v\n", err)
		os.Exit(1)
	}
}

func performScanForJSON(path string, isOverview bool) jsonOutput {
	if isOverview {
		return performOverviewScanForJSON(path)
	}
	return performDirectoryScanForJSON(path)
}

func performDirectoryScanForJSON(path string) jsonOutput {
	return performDirectoryScanForJSONWithProgress(path, nil, 0)
}

// performDirectoryScanForJSONWithProgress runs the concurrent scan and, when
// progress != nil, streams NDJSON progress events (read from the atomic scan
// counters every interval) to it until the scan completes — the engine half of
// the progressive-analyze slice, mirroring `status --watch`. progress == nil is
// the plain batch path.
func performDirectoryScanForJSONWithProgress(path string, progress io.Writer, interval time.Duration) jsonOutput {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	var stop chan struct{}
	if progress != nil {
		stop = make(chan struct{})
		go func() {
			ticker := time.NewTicker(interval)
			defer ticker.Stop()
			for {
				select {
				case <-stop:
					return
				case <-ticker.C:
					cur, _ := currentPath.Load().(string)
					_, _ = progress.Write(append(progressEvent(
						atomic.LoadInt64(&filesScanned),
						atomic.LoadInt64(&dirsScanned),
						atomic.LoadInt64(&bytesScanned),
						cur,
					), '\n'))
				}
			}
		}()
	}

	result, err := scanPathConcurrentAllEntries(path, &filesScanned, &dirsScanned, &bytesScanned, currentPath)
	if stop != nil {
		close(stop)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to scan directory: %v\n", err)
		os.Exit(1)
	}

	return jsonOutput{
		Path:       path,
		Overview:   false,
		Entries:    jsonEntriesFromDirEntries(result.Entries, false, nil),
		LargeFiles: jsonFileEntriesFromFileEntries(result.LargeFiles),
		TotalSize:  result.TotalSize,
		TotalFiles: result.TotalFiles,
	}
}

func performOverviewScanForJSON(path string) jsonOutput {
	insightEntries := createInsightEntries()
	overviewEntries := createOverviewEntriesWithInsights(insightEntries)
	insightPaths := make(map[string]bool, len(insightEntries))
	for _, insight := range insightEntries {
		insightPaths[insight.Path] = true
	}

	var totalSize int64
	entries := make([]dirEntry, 0, len(overviewEntries))
	for _, entry := range measureOverviewEntriesForJSON(overviewEntries, insightPaths) {
		// Match the TUI: omit scanned insight/tool entries that ended up empty.
		if entry.Size == 0 {
			continue
		}
		totalSize += entry.Size
		entries = append(entries, entry)
	}

	sort.SliceStable(entries, func(i, j int) bool {
		return entries[i].Size > entries[j].Size
	})

	return jsonOutput{
		Path:      path,
		Overview:  true,
		Entries:   jsonEntriesFromDirEntries(entries, true, insightPaths),
		TotalSize: totalSize,
	}
}

func measureOverviewEntriesForJSON(overviewEntries []dirEntry, insightPaths map[string]bool) []dirEntry {
	if len(overviewEntries) == 0 {
		return nil
	}

	type measurement struct {
		index int
		entry dirEntry
	}

	measured := make([]dirEntry, len(overviewEntries))
	sem := make(chan struct{}, maxConcurrentOverview)
	results := make(chan measurement, len(overviewEntries))

	var wg sync.WaitGroup
	for index, item := range overviewEntries {
		wg.Go(func() {
			sem <- struct{}{}
			defer func() { <-sem }()

			var (
				size int64
				err  error
			)

			if cached, cacheErr := loadOverviewCachedSize(item.Path); cacheErr == nil && cached > 0 {
				size = cached
			} else if insightPaths[item.Path] {
				size, err = measureInsightSize(item.Path)
			} else {
				size, err = measureOverviewSize(item.Path)
			}

			if err == nil {
				item.Size = size
			}
			results <- measurement{index: index, entry: item}
		})
	}

	wg.Wait()
	close(results)

	for result := range results {
		measured[result.index] = result.entry
	}
	return measured
}

func jsonEntriesFromDirEntries(entries []dirEntry, isOverview bool, insightPaths map[string]bool) []jsonEntry {
	output := make([]jsonEntry, 0, len(entries))
	for _, entry := range entries {
		item := jsonEntry{
			Name:      entry.Name,
			Path:      entry.Path,
			Size:      entry.Size,
			IsDir:     entry.IsDir,
			Cleanable: entry.IsDir && isCleanableDir(entry.Path),
		}

		if isOverview {
			item.Insight = insightPaths[entry.Path]
		}

		if !entry.LastAccess.IsZero() {
			item.LastAccess = entry.LastAccess.UTC().Format(time.RFC3339)
		}

		output = append(output, item)
	}
	return output
}

func jsonFileEntriesFromFileEntries(files []fileEntry) []jsonFileEntry {
	output := make([]jsonFileEntry, 0, len(files))
	for _, f := range files {
		output = append(output, jsonFileEntry(f))
	}
	return output
}
