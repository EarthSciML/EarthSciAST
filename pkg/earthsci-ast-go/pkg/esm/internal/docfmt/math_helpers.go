package docfmt

// Helpers the math layer needs that belong with the foundation files
// (number.go); kept here so the math port does not edit them.

import "strconv"

// numNatDigits is `Number.natDigits`: the decimal digits, [0] for zero.
func numNatDigits(n uint64) []byte {
	s := strconv.FormatUint(n, 10)
	ds := make([]byte, len(s))
	for i := range s {
		ds[i] = s[i] - '0'
	}
	return ds
}
