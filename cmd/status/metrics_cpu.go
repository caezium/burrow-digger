package main

import (
	"bufio"
	"context"
	"errors"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/load"
)

const (
	// minCPUSampleWindow is the shortest tick window we will report a percentage
	// from. macOS credits the per-CPU tick counters behind host_processor_info at
	// kern.clockrate hz (100), so a 100ms window only accrues ~10 ticks per core
	// and every per-core reading collapses onto a multiple of ~1/10 — the coarse
	// 0 / 9.09 / 55.56 / 66.67 values from Burrow #335. 600ms gives ~60 ticks per
	// core, which puts per-core quantization under 2 points.
	minCPUSampleWindow = 600 * time.Millisecond
	// maxCPUSampleWindow bounds how stale a cached baseline may be. Past this the
	// delta describes a long-gone average rather than "now", so we resample.
	maxCPUSampleWindow = 5 * time.Minute
)

// cpuTimesFunc is indirected so tests can drive the sampler with synthetic ticks.
var cpuTimesFunc = cpu.Times

// primeCPUCounters takes the first tick baseline, at construction, so the window
// a one-shot run has to wait out is as short as possible.
func (c *Collector) primeCPUCounters(now time.Time) {
	times, err := cpuTimesFunc(true)
	if err != nil || len(times) == 0 {
		return
	}
	c.prevCPUTimes = times
	c.lastCPUAt = now
}

func (c *Collector) collectCPU(now time.Time) (CPUStatus, error) {
	return c.collectCPUWithOptions(now, true)
}

func (c *Collector) collectCPUFast(now time.Time) (CPUStatus, error) {
	return c.collectCPUWithOptions(now, false)
}

func (c *Collector) collectCPUWithOptions(now time.Time, includeSlowFallbacks bool) (CPUStatus, error) {
	counts, countsErr := cpu.Counts(false)
	if countsErr != nil || counts == 0 {
		counts = runtime.NumCPU()
	}

	logical, logicalErr := cpu.Counts(true)
	if logicalErr != nil || logical == 0 {
		logical = runtime.NumCPU()
	}
	if logical <= 0 {
		logical = 1
	}

	totalPercent, percents, err := c.cpuUsageSinceBaseline(now, includeSlowFallbacks)
	perCoreEstimated := false
	if err != nil || len(percents) == 0 {
		if !includeSlowFallbacks {
			// Fast path: never block for a fresh window. Report zeroed per-core
			// usage and let the next refresh, which has a real baseline, correct it.
			totalPercent = 0
			percents = make([]float64, logical)
			perCoreEstimated = true
		} else {
			fallbackUsage, fallbackPerCore, fallbackErr := fallbackCPUUtilization(logical)
			if fallbackErr != nil {
				if err != nil {
					return CPUStatus{}, err
				}
				return CPUStatus{}, fallbackErr
			}
			totalPercent = fallbackUsage
			percents = fallbackPerCore
			perCoreEstimated = true
		}
	}

	loadStats, loadErr := load.Avg()
	var loadAvg load.AvgStat
	if loadStats != nil {
		loadAvg = *loadStats
	}
	if includeSlowFallbacks && (loadErr != nil || isZeroLoad(loadAvg)) {
		if fallback, err := fallbackLoadAvgFromUptime(); err == nil {
			loadAvg = fallback
		}
	}

	// P/E core counts for Apple Silicon.
	var pCores, eCores int
	if includeSlowFallbacks {
		pCores, eCores = getCoreTopology()
	}

	return CPUStatus{
		Usage:            totalPercent,
		PerCore:          percents,
		PerCoreEstimated: perCoreEstimated,
		Load1:            loadAvg.Load1,
		Load5:            loadAvg.Load5,
		Load15:           loadAvg.Load15,
		CoreCount:        counts,
		LogicalCPU:       logical,
		PCoreCount:       pCores,
		ECoreCount:       eCores,
	}, nil
}

func isZeroLoad(avg load.AvgStat) bool {
	return avg.Load1 == 0 && avg.Load5 == 0 && avg.Load15 == 0
}

var (
	// Cache for core topology.
	lastTopologyAt   time.Time
	cachedP, cachedE int
	topologyTTL      = 10 * time.Minute
)

// getCoreTopology returns P/E core counts on Apple Silicon.
func getCoreTopology() (pCores, eCores int) {
	if runtime.GOOS != "darwin" {
		return 0, 0
	}

	now := time.Now()
	if cachedP > 0 || cachedE > 0 {
		if now.Sub(lastTopologyAt) < topologyTTL {
			return cachedP, cachedE
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	out, err := runCmd(ctx, "sysctl", "-n",
		"hw.perflevel0.logicalcpu",
		"hw.perflevel0.name",
		"hw.perflevel1.logicalcpu",
		"hw.perflevel1.name")
	if err != nil {
		return 0, 0
	}

	var lines []string
	for line := range strings.Lines(strings.TrimSpace(out)) {
		lines = append(lines, line)
	}
	if len(lines) < 4 {
		return 0, 0
	}

	level0Count, _ := strconv.Atoi(strings.TrimSpace(lines[0]))
	level0Name := strings.ToLower(strings.TrimSpace(lines[1]))

	level1Count, _ := strconv.Atoi(strings.TrimSpace(lines[2]))
	level1Name := strings.ToLower(strings.TrimSpace(lines[3]))

	if strings.Contains(level0Name, "performance") {
		pCores = level0Count
	} else if strings.Contains(level0Name, "efficiency") {
		eCores = level0Count
	}

	if strings.Contains(level1Name, "performance") {
		pCores = level1Count
	} else if strings.Contains(level1Name, "efficiency") {
		eCores = level1Count
	}

	cachedP, cachedE = pCores, eCores
	lastTopologyAt = now
	return pCores, eCores
}

func fallbackLoadAvgFromUptime() (load.AvgStat, error) {
	if !commandExists("uptime") {
		return load.AvgStat{}, errors.New("uptime command unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	out, err := runCmd(ctx, "uptime")
	if err != nil {
		return load.AvgStat{}, err
	}

	markers := []string{"load averages:", "load average:"}
	idx := -1
	for _, marker := range markers {
		if pos := strings.LastIndex(out, marker); pos != -1 {
			idx = pos + len(marker)
			break
		}
	}
	if idx == -1 {
		return load.AvgStat{}, errors.New("load averages not found in uptime output")
	}

	segment := strings.TrimSpace(out[idx:])
	fields := strings.Fields(segment)
	var values []float64
	for _, field := range fields {
		field = strings.Trim(field, ",;")
		if field == "" {
			continue
		}
		val, err := strconv.ParseFloat(field, 64)
		if err != nil {
			continue
		}
		values = append(values, val)
		if len(values) == 3 {
			break
		}
	}
	if len(values) < 3 {
		return load.AvgStat{}, errors.New("could not parse load averages from uptime output")
	}

	return load.AvgStat{
		Load1:  values[0],
		Load5:  values[1],
		Load15: values[2],
	}, nil
}

func fallbackCPUUtilization(logical int) (float64, []float64, error) {
	if logical <= 0 {
		logical = runtime.NumCPU()
	}
	if logical <= 0 {
		logical = 1
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	out, err := runCmd(ctx, "ps", "-Aceo", "pcpu")
	if err != nil {
		return 0, nil, err
	}

	scanner := bufio.NewScanner(strings.NewReader(out))
	total := 0.0
	lineIndex := 0
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		lineIndex++
		if lineIndex == 1 && (strings.Contains(strings.ToLower(line), "cpu") || strings.Contains(line, "%")) {
			continue
		}

		val, parseErr := strconv.ParseFloat(line, 64)
		if parseErr != nil {
			continue
		}
		total += val
	}
	if scanErr := scanner.Err(); scanErr != nil {
		return 0, nil, scanErr
	}

	maxTotal := float64(logical * 100)
	if total < 0 {
		total = 0
	} else if total > maxTotal {
		total = maxTotal
	}

	avg := total / float64(logical)
	perCore := make([]float64, logical)
	for i := range perCore {
		perCore[i] = avg
	}
	return avg, perCore, nil
}

// cpuUsageSinceBaseline turns the collector's cached tick baseline and a fresh
// reading into a total plus per-core percentages.
//
// Reusing the baseline across refreshes is what makes the number trustworthy: in
// `--watch` and the TUI the window becomes the whole refresh interval, and in a
// one-shot run it spans the entire collection pass. Both are wide enough to
// accrue hundreds of ticks per core, so the reading stops jumping and stops
// being dominated by whatever the collector itself was doing.
//
// mayBlock allows the slow path to sleep out the remainder of the minimum window
// when the baseline is too young to divide by; the fast path never blocks.
func (c *Collector) cpuUsageSinceBaseline(now time.Time, mayBlock bool) (float64, []float64, error) {
	cur, err := cpuTimesFunc(true)
	if err != nil {
		return 0, nil, err
	}
	if len(cur) == 0 {
		return 0, nil, errors.New("no per-cpu times available")
	}

	baseline := c.prevCPUTimes
	elapsed := now.Sub(c.lastCPUAt)
	haveBaseline := !c.lastCPUAt.IsZero() && len(baseline) == len(cur) && elapsed > 0

	switch {
	case haveBaseline && elapsed >= minCPUSampleWindow && elapsed <= maxCPUSampleWindow:
		// The common path: the previous refresh left a baseline wide enough to use.
	case !mayBlock:
		// Fast path with a young or missing baseline. A sub-window delta is still a
		// real measurement (just noisier), so report it rather than blocking; only
		// a wholly missing baseline gives up and lets the caller zero the reading.
		if !haveBaseline {
			c.prevCPUTimes, c.lastCPUAt = cur, now
			return 0, nil, errors.New("cpu baseline not ready")
		}
	default:
		// Slow path: sleep out whatever the window is still short by. A baseline
		// that is merely young is extended rather than discarded, so we sleep the
		// remainder instead of a full window.
		wait := minCPUSampleWindow
		if haveBaseline && elapsed < minCPUSampleWindow {
			wait = minCPUSampleWindow - elapsed
		} else {
			baseline = cur
		}
		time.Sleep(wait)
		fresh, freshErr := cpuTimesFunc(true)
		if freshErr != nil {
			return 0, nil, freshErr
		}
		if len(fresh) != len(baseline) {
			return 0, nil, errors.New("cpu core count changed mid-sample")
		}
		cur, now = fresh, time.Now()
	}

	total, perCore, ticks := cpuPercentFromTimes(baseline, cur)
	c.prevCPUTimes, c.lastCPUAt = cur, now
	if ticks <= 0 {
		// The window closed before the counters advanced (a fast-path refresh that
		// landed almost on top of the baseline). Reporting 0% would read as "idle";
		// let the caller mark the reading unavailable instead.
		return 0, nil, errors.New("cpu sample window accrued no ticks")
	}
	return total, perCore, nil
}

// cpuPercentFromTimes converts two per-CPU tick snapshots into per-core busy
// percentages and a total.
//
// The total is derived from summed tick deltas rather than by averaging the
// per-core percentages. Cores don't all report the same number of ticks in a
// window — a core that was parked may contribute only one or two — and an
// unweighted mean lets those thin samples swing the total as hard as a fully
// sampled core. Summing first weights every core by the time it actually
// accounted for.
// It also returns the total tick delta the window accrued, so callers can tell a
// genuinely idle machine from a window that closed too early to measure anything.
func cpuPercentFromTimes(prev, cur []cpu.TimesStat) (total float64, perCore []float64, ticks float64) {
	perCore = make([]float64, len(cur))
	var totalBusy float64
	for i := range cur {
		busy, all := cpuBusyTotal(prev[i], cur[i])
		if all > 0 {
			perCore[i] = clampPercent(busy / all * 100)
		}
		totalBusy += busy
		ticks += all
	}
	if ticks <= 0 {
		return 0, perCore, 0
	}
	return clampPercent(totalBusy / ticks * 100), perCore, ticks
}

// cpuBusyTotal returns the busy and total tick deltas between two samples of one
// CPU. Deltas are floored at zero so a counter reset can't produce a negative.
func cpuBusyTotal(prev, cur cpu.TimesStat) (busy, total float64) {
	delta := func(a, b float64) float64 {
		if d := b - a; d > 0 {
			return d
		}
		return 0
	}
	idle := delta(prev.Idle, cur.Idle)
	busy = delta(prev.User, cur.User) + delta(prev.System, cur.System) +
		delta(prev.Nice, cur.Nice) + delta(prev.Iowait, cur.Iowait) +
		delta(prev.Irq, cur.Irq) + delta(prev.Softirq, cur.Softirq) +
		delta(prev.Steal, cur.Steal)
	return busy, busy + idle
}

func clampPercent(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}
