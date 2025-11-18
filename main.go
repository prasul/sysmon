package main

import (
	"bufio"    // For reading files line-by-line efficiently
	"fmt"      // For printing to the console
	"os"       // For opening files
	"sort"     // For sorting our results
	"strings"  // For splitting strings
)

// We need a custom data structure to hold our IP counts
// so we can sort them. Maps in Go are not inherently sortable.
type IPCount struct {
	IP    string
	Count int
}

func main() {
	fmt.Println("[+] Starting Server Load Report (Segment 1)...")

	// --- Step 1: Create a map to store IP counts ---
	// A map is a key-value store. We will store:
	// "104.28.2.19" -> 452
	// "192.0.2.1"   -> 211
	ipCounts := make(map[string]int)

	// --- Step 2: Open our sample log file ---
	// We use "os.Open" to get a file handle.
	file, err := os.Open("sample_access.log")
	if err != nil {
		// If the file isn't found, print a fatal error
		fmt.Println("[FATAL] Could not open sample_access.log:", err)
		os.Exit(1)
	}
	// 'defer' ensures this runs at the end of the function,
	// so the file is always closed.
	defer file.Close()

	// --- Step 3: Read the file line-by-line ---
	// bufio.NewScanner is the most efficient way to read a file line by line.
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		// Get the current line as a string
		line := scanner.Text()

		// Parse the line. In a basic Nginx log, the IP is the first field.
		// "strings.SplitN" splits the string by a delimiter (" ") but stops
		// after N items (we only need 2 to get the first part).
		fields := strings.SplitN(line, " ", 2)
		if len(fields) > 0 {
			ip := fields[0]
			// Increment the count for this IP in our map
			ipCounts[ip]++
		}
	}

	// Check if the scanner itself had an error (e.g., file corrupted)
	if err := scanner.Err(); err != nil {
		fmt.Println("[ERROR] Error while reading file:", err)
	}

	// --- Step 4: Sort the results ---
	// We can't sort a map directly. The standard Go way is:
	// 1. Create a slice of our custom struct
	var sortedCounts []IPCount
	// 2. Copy the map data into the slice
	for ip, count := range ipCounts {
		sortedCounts = append(sortedCounts, IPCount{IP: ip, Count: count})
	}

	// 3. Sort the slice using the 'sort' package.
	// We provide a custom "less" function to sort in DESCENDING order (highest count first).
	sort.Slice(sortedCounts, func(i, j int) bool {
		return sortedCounts[i].Count > sortedCounts[j].Count
	})

	// --- Step 5: Print the Top 5 ---
	fmt.Println("\n--- [BOLD UNDERLINE]GLOBAL TOP 5 HITTING IPs[/] ---")
	
	// Determine how many to print (don't crash if there are fewer than 5)
	numToPrint := 5
	if len(sortedCounts) < 5 {
		numToPrint = len(sortedCounts)
	}

	for i := 0; i < numToPrint; i++ {
		entry := sortedCounts[i]
		fmt.Printf("%d. %-15s .................... %d hits\n", i+1, entry.IP, entry.Count)
	}
}
