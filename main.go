package main

import (
	"bufio"   // For reading files line-by-line
	"fmt"     // For printing
	"os"      // For opening files/args
	"runtime" // To detect if we are on Linux or Mac
	"sort"    // For sorting
	"strconv" // For string conversion
	"strings" // For splitting strings
)

// --- Color Definitions ---
const (
	ColorReset  = "\033[0m"
	ColorRed    = "\033[31m"
	ColorGreen  = "\033[32m"
	ColorYellow = "\033[33m"
	ColorCyan   = "\033[36m"
	ColorBold   = "\033[1m"
)

type IPCount struct {
	IP    string
	Count int
}

// --- Helper: Parse Memory Values from /proc/meminfo ---
func getRAMUsage() string {
	// Default placeholder for Mac/Windows
	if runtime.GOOS != "linux" {
		return "4.5GB / 16.0GB (Mac/Dev Mode)"
	}

	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return "Unknown"
	}

	var totalKB, availKB int
	lines := strings.Split(string(data), "\n")

	// Loop through lines to find MemTotal and MemAvailable
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if fields[0] == "MemTotal:" {
			totalKB, _ = strconv.Atoi(fields[1])
		} else if fields[0] == "MemAvailable:" {
			availKB, _ = strconv.Atoi(fields[1])
		}
	}

	// Calculate Used
	usedKB := totalKB - availKB
	
	// Avoid division by zero if parsing failed
	if totalKB == 0 {
		return "Unknown"
	}

	// Convert to GB for display
	totalGB := float64(totalKB) / 1024 / 1024
	usedGB := float64(usedKB) / 1024 / 1024
	percent := (float64(usedKB) / float64(totalKB)) * 100

	// Return formatted string (e.g., "4.50GB / 16.00GB (28.1%)")
	return fmt.Sprintf("%.2fGB / %.2fGB (%.1f%%)", usedGB, totalGB, percent)
}

// --- Get System Stats ---
// Returns (hostname, loadAverage, ramUsage)
func getSystemStats() (string, string, string) {
	// 1. Hostname
	hostname, err := os.Hostname()
	if err != nil {
		hostname = "Unknown"
	}

	// 2. Load Average
	loadAvg := "0.00 0.00 0.00 (Mac/Dev Mode)"
	if runtime.GOOS == "linux" {
		data, err := os.ReadFile("/proc/loadavg")
		if err == nil {
			content := string(data)
			fields := strings.Fields(content)
			if len(fields) >= 3 {
				loadAvg = fmt.Sprintf("%s %s %s", fields[0], fields[1], fields[2])
			}
		}
	}

	// 3. RAM Usage
	ramUsage := getRAMUsage()

	return hostname, loadAvg, ramUsage
}

func main() {
	// --- Step 0: Print the UI Header (Updated with RAM) ---
	host, load, ram := getSystemStats()
	
	fmt.Print("\033[H\033[2J") // Clear screen

	fmt.Println("#################################################################")
	fmt.Printf("# SERVER MONITOR | Host: %s%s%s | OS: %s\n", ColorCyan, host, ColorReset, runtime.GOOS)
	fmt.Printf("# Load Average: %s%s%s\n", ColorGreen, load, ColorReset)
	fmt.Printf("# RAM Usage:    %s%s%s\n", ColorYellow, ram, ColorReset)
	fmt.Println("#################################################################")
	fmt.Println("")

	// --- Step 1: Get Log Path ---
	logFilePath := "sample_access.log"
	if len(os.Args) > 1 {
		logFilePath = os.Args[1]
	} else {
		fmt.Printf("%s[INFO] Using default log: sample_access.log%s\n", ColorYellow, ColorReset)
	}

	// --- Step 2: Parse Log ---
	ipCounts := make(map[string]int)

	file, err := os.Open(logFilePath)
	if err != nil {
		fmt.Printf("%s[FATAL] Could not open file '%s': %v%s\n", ColorRed, logFilePath, err, ColorReset)
		os.Exit(1)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		fields := strings.SplitN(line, " ", 2)
		if len(fields) > 0 {
			ip := fields[0]
			ipCounts[ip]++
		}
	}

	// --- Step 3: Sort and Print ---
	var sortedCounts []IPCount
	for ip, count := range ipCounts {
		sortedCounts = append(sortedCounts, IPCount{IP: ip, Count: count})
	}

	sort.Slice(sortedCounts, func(i, j int) bool {
		return sortedCounts[i].Count > sortedCounts[j].Count
	})

	fmt.Printf("--- %sGLOBAL TOP 5 HITTING IPs%s ---\n", ColorBold, ColorReset)
	numToPrint := 5
	if len(sortedCounts) < 5 {
		numToPrint = len(sortedCounts)
	}

	for i := 0; i < numToPrint; i++ {
		entry := sortedCounts[i]
		fmt.Printf("%d. %-15s .................... %s%d hits%s\n", 
			i+1, entry.IP, ColorRed, entry.Count, ColorReset)
	}
}
