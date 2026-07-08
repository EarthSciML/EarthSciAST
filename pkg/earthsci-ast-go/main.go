package main

import (
	"fmt"
	"log"
	"os"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	command := os.Args[1]
	switch command {
	case "parse", "load":
		if len(os.Args) < 3 {
			log.Fatal("Usage: esm-go parse <file>")
		}
		parseFile(os.Args[2])
	case "validate":
		if len(os.Args) < 3 {
			log.Fatal("Usage: esm-go validate <file>")
		}
		validateFile(os.Args[2])
	case "pretty-print":
		if len(os.Args) < 3 {
			log.Fatal("Usage: esm-go pretty-print <file> [format]")
		}
		format := "unicode"
		if len(os.Args) >= 4 {
			format = os.Args[3]
		}
		prettyPrintFile(os.Args[2], format)
	case "substitute":
		if len(os.Args) < 4 {
			log.Fatal("Usage: esm-go substitute <file> <var=value> [var=value...]")
		}
		substituteFile(os.Args[2], os.Args[3:])
	case "save", "serialize":
		if len(os.Args) < 4 {
			log.Fatal("Usage: esm-go save <input-file> <output-file>")
		}
		saveFile(os.Args[2], os.Args[3])
	case "summary":
		if len(os.Args) < 3 {
			log.Fatal("Usage: esm-go summary <file>")
		}
		summaryFile(os.Args[2])
	default:
		fmt.Printf("Unknown command: %s\n", command)
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println("Usage: esm-go <command> [args]")
	fmt.Println("Commands:")
	fmt.Println("  parse <file>                    - Parse and load an ESM file")
	fmt.Println("  validate <file>                 - Validate an ESM file")
	fmt.Println("  pretty-print <file> [format]    - Pretty-print expressions (format: unicode, latex, ascii)")
	fmt.Println("  substitute <file> <var=value>   - Substitute variables in expressions")
	fmt.Println("  save <input> <output>           - Save ESM file to new location")
	fmt.Println("  summary <file>                  - Display structured model summary")
}

func parseFile(filename string) {
	fmt.Printf("Parsing file: %s\n", filename)

	esmFile, err := esm.Load(filename)
	if err != nil {
		log.Fatalf("Failed to load ESM file: %v", err)
	}

	fmt.Printf("Successfully parsed ESM file version %s\n", esmFile.Esm)
	fmt.Printf("Model name: %s\n", esmFile.Metadata.Name)
	fmt.Printf("Authors: %v\n", esmFile.Metadata.Authors)

	if len(esmFile.Models) > 0 {
		fmt.Printf("Models: %d\n", len(esmFile.Models))
	}
	if len(esmFile.ReactionSystems) > 0 {
		fmt.Printf("Reaction Systems: %d\n", len(esmFile.ReactionSystems))
	}
	if len(esmFile.DataLoaders) > 0 {
		fmt.Printf("Data Loaders: %d\n", len(esmFile.DataLoaders))
	}
	if len(esmFile.Enums) > 0 {
		fmt.Printf("Enums: %d\n", len(esmFile.Enums))
	}
}

func validateFile(filename string) {
	fmt.Printf("Validating file: %s\n", filename)

	esmFile, err := esm.Load(filename)
	if err != nil {
		log.Fatalf("Failed to load ESM file: %v", err)
	}

	result := esm.Validate(esmFile)

	if result.Valid {
		fmt.Printf("✓ File %s is valid\n", filename)
	} else {
		fmt.Printf("✗ File %s has validation errors:\n", filename)
		for _, msg := range result.Messages {
			fmt.Printf("  [%s] %s (at %s)\n", msg.Level, msg.Message, msg.Path)
		}
		os.Exit(1)
	}
}

func prettyPrintFile(filename, format string) {
	fmt.Printf("Pretty-printing file: %s (format: %s)\n", filename, format)

	esmFile, err := esm.Load(filename)
	if err != nil {
		log.Fatalf("Failed to load ESM file: %v", err)
	}

	// Pretty-print expressions from models
	for modelName, model := range esmFile.Models {
		fmt.Printf("\nModel: %s\n", modelName)
		for i, eq := range model.Equations {
			var lhsStr, rhsStr string

			switch format {
			case "latex":
				lhsStr = esm.ToLatex(eq.LHS)
				rhsStr = esm.ToLatex(eq.RHS)
			case "ascii":
				lhsStr = fmt.Sprintf("%v", eq.LHS)
				rhsStr = fmt.Sprintf("%v", eq.RHS)
			default:
				lhsStr = esm.ToUnicode(eq.LHS)
				rhsStr = esm.ToUnicode(eq.RHS)
			}

			fmt.Printf("  Equation %d: %s = %s\n", i+1, lhsStr, rhsStr)
		}
	}

	// Pretty-print expressions from reaction systems
	for systemName, system := range esmFile.ReactionSystems {
		fmt.Printf("\nReaction System: %s\n", systemName)
		for _, reaction := range system.Reactions {
			var rateStr string

			switch format {
			case "latex":
				rateStr = esm.ToLatex(reaction.Rate)
			case "ascii":
				rateStr = fmt.Sprintf("%v", reaction.Rate)
			default:
				rateStr = esm.ToUnicode(reaction.Rate)
			}

			fmt.Printf("  Reaction %s: rate = %s\n", reaction.ID, rateStr)
		}
	}
}

func substituteFile(filename string, substitutions []string) {
	fmt.Printf("Substituting variables in file: %s\n", filename)

	esmFile, err := esm.Load(filename)
	if err != nil {
		log.Fatalf("Failed to load ESM file: %v", err)
	}

	// Parse substitutions (var=value format)
	bindings := make(map[string]esm.Expression)
	for _, sub := range substitutions {
		parts := parseSubstitution(sub)
		if len(parts) != 2 {
			log.Fatalf("Invalid substitution format: %s (expected var=value)", sub)
		}

		// Try to parse as number first, then as string
		var value esm.Expression = parts[1] // Default to string
		if num := parseNumber(parts[1]); num != nil {
			value = *num
		}

		bindings[parts[0]] = value
		fmt.Printf("  %s → %v\n", parts[0], value)
	}

	// Apply substitutions
	newFile := esm.SubstituteInFile(*esmFile, bindings)

	// Serialize and print the result
	jsonStr, err := esm.Save(&newFile)
	if err != nil {
		log.Fatalf("Failed to serialize result: %v", err)
	}

	fmt.Println("\nResult:")
	fmt.Println(jsonStr)
}

func saveFile(inputFile, outputFile string) {
	fmt.Printf("Saving file: %s → %s\n", inputFile, outputFile)

	esmFile, err := esm.Load(inputFile)
	if err != nil {
		log.Fatalf("Failed to load ESM file: %v", err)
	}

	err = esm.SaveToFile(esmFile, outputFile)
	if err != nil {
		log.Fatalf("Failed to save file: %v", err)
	}

	fmt.Printf("Successfully saved to %s\n", outputFile)
}

func summaryFile(filename string) {
	esmFile, err := esm.Load(filename)
	if err != nil {
		log.Fatalf("Failed to load ESM file: %v", err)
	}

	summary := esm.ModelSummary(esmFile)
	fmt.Println(summary)
}

// Helper functions

func parseSubstitution(sub string) []string {
	for i, char := range sub {
		if char == '=' {
			return []string{sub[:i], sub[i+1:]}
		}
	}
	return []string{sub}
}

func parseNumber(s string) *float64 {
	var num float64
	n, err := fmt.Sscanf(s, "%g", &num)
	if err != nil || n != 1 {
		return nil
	}
	return &num
}