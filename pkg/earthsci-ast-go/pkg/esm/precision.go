package esm

// PrecisionSource returns the declared element type or "unspecified" (§11.3.3).
// A nil variable queries the document default, including for reaction species
// and parameters.
func PrecisionSource(document *ESMFile, variable *ModelVariable) string {
	if variable != nil && variable.ElementType != nil {
		return *variable.ElementType
	}
	if document.Domain != nil && document.Domain.ElementType != nil {
		return *document.Domain.ElementType
	}
	return omittedPrecision(document.ESM)
}

func omittedPrecision(version string) string {
	if parsed, ok := parseSemVer(version); ok && (parsed.Major > 1 || parsed.Major == 1 && parsed.Minor >= 3) {
		return "unspecified"
	}
	return "Float64"
}
