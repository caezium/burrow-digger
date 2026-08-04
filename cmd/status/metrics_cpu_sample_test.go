package main

import (
	"errors"
	"math"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
)

// ticks builds a per-CPU snapshot from (busy, idle) pairs expressed in ticks.
func ticks(pairs ...[2]float64) []cpu.TimesStat {
	out := make([]cpu.TimesStat, len(pairs))
	for i, p := range pairs {
		out[i] = cpu.TimesStat{User: p[0], Idle: p[1]}
	}
	return out
}

func stubCPUTimes(t *testing.T, samples ...[]cpu.TimesStat) *int {
	t.Helper()
	orig := cpuTimesFunc
	t.Cleanup(func() { cpuTimesFunc = orig })

	calls := 0
	cpuTimesFunc = func(percpu bool) ([]cpu.TimesStat, error) {
		if calls >= len(samples) {
			return nil, errors.New("no more stubbed samples")
		}
		s := samples[calls]
		calls++
		return s, nil
	}
	return &calls
}

func approx(t *testing.T, got, want float64, label string) {
	t.Helper()
	if math.Abs(got-want) > 0.01 {
		t.Fatalf("%s = %.4f, want %.4f", label, got, want)
	}
}

// The total must come from summed tick deltas, not from averaging the per-core
// percentages. Here one core reports a single busy tick while three fully-sampled
// cores are almost idle: an unweighted mean says ~28%, the tick-weighted answer
// is ~4%. Burrow #335 was this shape of over-report.
func TestCPUTotalIsTickWeightedNotMeanOfCores(t *testing.T) {
	prev := ticks([2]float64{0, 0}, [2]float64{0, 0}, [2]float64{0, 0}, [2]float64{0, 0})
	cur := ticks(
		[2]float64{1, 0},  // parked core, one busy tick, 100%
		[2]float64{4, 96}, // 4%
		[2]float64{4, 96}, // 4%
		[2]float64{4, 96}, // 4%
	)

	total, perCore, tickTotal := cpuPercentFromTimes(prev, cur)

	approx(t, perCore[0], 100, "perCore[0]")
	approx(t, perCore[1], 4, "perCore[1]")
	approx(t, tickTotal, 301, "tick total")

	// 13 busy ticks out of 301 observed.
	approx(t, total, 13.0/301.0*100, "total")

	var mean float64
	for _, v := range perCore {
		mean += v
	}
	mean /= float64(len(perCore))
	if mean-total < 20 {
		t.Fatalf("expected the unweighted mean (%.2f) to overstate the tick-weighted total (%.2f)", mean, total)
	}
}

func TestCPUPercentClampsCounterResets(t *testing.T) {
	prev := ticks([2]float64{500, 500})
	cur := ticks([2]float64{10, 20}) // counters went backwards

	total, perCore, tickTotal := cpuPercentFromTimes(prev, cur)
	if total != 0 || perCore[0] != 0 || tickTotal != 0 {
		t.Fatalf("counter reset should floor to zero, got total=%v perCore=%v ticks=%v", total, perCore, tickTotal)
	}
}

// A baseline wide enough to use must be consumed directly — no sleeping, and no
// discarding it in favour of a fresh short window.
func TestCPUUsesCachedBaselineWithoutBlocking(t *testing.T) {
	c := &Collector{
		prevCPUTimes: ticks([2]float64{0, 0}, [2]float64{0, 0}),
		lastCPUAt:    time.Now().Add(-time.Second),
	}
	calls := stubCPUTimes(t, ticks([2]float64{25, 75}, [2]float64{75, 25}))

	start := time.Now()
	total, perCore, err := c.cpuUsageSinceBaseline(time.Now(), true)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("cpuUsageSinceBaseline() error = %v", err)
	}
	if *calls != 1 {
		t.Fatalf("expected a single tick read against the cached baseline, got %d", *calls)
	}
	if elapsed >= minCPUSampleWindow {
		t.Fatalf("a usable baseline must not sleep; slept %v", elapsed)
	}
	approx(t, perCore[0], 25, "perCore[0]")
	approx(t, perCore[1], 75, "perCore[1]")
	approx(t, total, 50, "total")
}

// A baseline older than maxCPUSampleWindow describes a long-gone average, so the
// sampler must take a fresh window instead of dividing by it.
func TestCPUResamplesWhenBaselineIsStale(t *testing.T) {
	c := &Collector{
		prevCPUTimes: ticks([2]float64{0, 0}),
		lastCPUAt:    time.Now().Add(-2 * maxCPUSampleWindow),
	}
	calls := stubCPUTimes(t,
		ticks([2]float64{1000, 1000}), // fresh baseline
		ticks([2]float64{1030, 1070}), // after the window
	)

	total, _, err := c.cpuUsageSinceBaseline(time.Now(), true)
	if err != nil {
		t.Fatalf("cpuUsageSinceBaseline() error = %v", err)
	}
	if *calls != 2 {
		t.Fatalf("stale baseline should force a fresh window (2 reads), got %d", *calls)
	}
	approx(t, total, 30, "total") // 30 busy of 100 ticks
}

// The fast path must never block, even with no baseline at all.
func TestCPUFastPathNeverBlocks(t *testing.T) {
	c := &Collector{}
	stubCPUTimes(t, ticks([2]float64{10, 90}))

	start := time.Now()
	_, _, err := c.cpuUsageSinceBaseline(time.Now(), false)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected an error when no baseline exists")
	}
	if elapsed >= minCPUSampleWindow {
		t.Fatalf("fast path must not sleep; slept %v", elapsed)
	}
	if len(c.prevCPUTimes) != 1 {
		t.Fatal("fast path should still leave a baseline for the next refresh")
	}
}

// A window that closes before the counters advance is unmeasurable, not idle.
func TestCPUZeroTickWindowIsAnError(t *testing.T) {
	base := ticks([2]float64{100, 100})
	c := &Collector{prevCPUTimes: base, lastCPUAt: time.Now().Add(-time.Millisecond)}
	stubCPUTimes(t, base) // identical counters: no ticks accrued

	if _, _, err := c.cpuUsageSinceBaseline(time.Now(), false); err == nil {
		t.Fatal("a zero-tick window must report as unavailable, not 0%")
	}
}

// Regression guard for the sampling window itself: 100ms only accrues ~10 ticks
// per core on macOS, which is what quantized per-core readings to multiples of
// ~10% in Burrow #335.
func TestCPUSampleWindowIsWideEnoughToResolvePercentPoints(t *testing.T) {
	const darwinTickHz = 100
	ticksPerCore := minCPUSampleWindow.Seconds() * darwinTickHz
	if ticksPerCore < 50 {
		t.Fatalf("minCPUSampleWindow=%v yields only %.0f ticks per core; per-core readings quantize to %.1f%% steps",
			minCPUSampleWindow, ticksPerCore, 100/ticksPerCore)
	}
}
