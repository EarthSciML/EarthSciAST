#!/bin/bash

# EarthSciAST Environment Setup and Installation Script
# Provides automated setup for development environments across all supported languages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${CYAN}"
    echo "=============================================="
    echo "  EarthSciAST Environment Setup"
    echo "=============================================="
    echo -e "${NC}"
    echo ""
}

print_help() {
    cat << EOF
EarthSciAST Environment Setup

Usage: ./install.sh [options]

Options:
  --all                   Install all language environments and dependencies
  --typescript, --ts      Install TypeScript/Node.js environment
  --python, --py          Install Python environment
  --julia, --jl           Install Julia environment
  --rust, --rs            Install Rust environment
  --go, --golang          Install Go environment
  --dev                   Install development tools (linters, formatters, etc.)
  --check                 Check system requirements without installing
  --help, -h              Show this help message

Examples:
  ./install.sh --all              # Complete setup for all languages
  ./install.sh --ts --py          # Setup only TypeScript and Python
  ./install.sh --check            # Check what's installed
  ./install.sh --dev              # Install development tools

EOF
}

# Detect operating system
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
        echo "windows"
    else
        echo "unknown"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install package manager based on OS
install_package_manager() {
    local os=$(detect_os)

    case $os in
        "linux")
            if command_exists apt; then
                echo -e "${YELLOW}Using apt package manager${NC}"
                sudo apt update
            elif command_exists yum; then
                echo -e "${YELLOW}Using yum package manager${NC}"
                sudo yum check-update || true
            elif command_exists pacman; then
                echo -e "${YELLOW}Using pacman package manager${NC}"
                sudo pacman -Sy
            else
                echo -e "${RED}No supported package manager found${NC}"
                exit 1
            fi
            ;;
        "macos")
            if ! command_exists brew; then
                echo -e "${YELLOW}Installing Homebrew...${NC}"
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            echo -e "${YELLOW}Using brew package manager${NC}"
            brew update
            ;;
        "windows")
            echo -e "${YELLOW}Windows detected. Please ensure you have Windows Subsystem for Linux (WSL) or use package managers manually.${NC}"
            ;;
        *)
            echo -e "${RED}Unsupported operating system${NC}"
            exit 1
            ;;
    esac
}

# Check system requirements
check_requirements() {
    echo -e "${BLUE}🔍 Checking system requirements...${NC}\n"

    local requirements_met=true

    # Check for curl/wget
    if command_exists curl; then
        echo -e "${GREEN}✓ curl is available${NC}"
    elif command_exists wget; then
        echo -e "${GREEN}✓ wget is available${NC}"
    else
        echo -e "${RED}✗ Neither curl nor wget found${NC}"
        requirements_met=false
    fi

    # Check for git
    if command_exists git; then
        echo -e "${GREEN}✓ git is available ($(git --version))${NC}"
    else
        echo -e "${RED}✗ git is not installed${NC}"
        requirements_met=false
    fi

    # Check for jq (nice to have)
    if command_exists jq; then
        echo -e "${GREEN}✓ jq is available${NC}"
    else
        echo -e "${YELLOW}⚠ jq not found (recommended for JSON processing)${NC}"
    fi

    echo ""
    if [[ $requirements_met == true ]]; then
        return 0
    else
        return 1
    fi
}

# Check language environments
check_languages() {
    echo -e "${BLUE}🔍 Checking language environments...${NC}\n"

    # Node.js / TypeScript
    if command_exists node; then
        echo -e "${GREEN}✓ Node.js: $(node --version)${NC}"
        if command_exists npm; then
            echo -e "${GREEN}✓ npm: $(npm --version)${NC}"
        else
            echo -e "${YELLOW}⚠ npm not found${NC}"
        fi
    else
        echo -e "${RED}✗ Node.js not installed${NC}"
    fi

    # Python
    if command_exists python3; then
        echo -e "${GREEN}✓ Python: $(python3 --version)${NC}"
        if command_exists pip3; then
            echo -e "${GREEN}✓ pip3: $(pip3 --version)${NC}"
        else
            echo -e "${YELLOW}⚠ pip3 not found${NC}"
        fi
    else
        echo -e "${RED}✗ Python 3 not installed${NC}"
    fi

    # Julia
    if command_exists julia; then
        echo -e "${GREEN}✓ Julia: $(julia --version)${NC}"
    else
        echo -e "${RED}✗ Julia not installed${NC}"
    fi

    # Rust
    if command_exists cargo; then
        echo -e "${GREEN}✓ Rust: $(rustc --version)${NC}"
        echo -e "${GREEN}✓ Cargo: $(cargo --version)${NC}"
    else
        echo -e "${RED}✗ Rust not installed${NC}"
    fi

    # Go
    if command_exists go; then
        echo -e "${GREEN}✓ Go: $(go version)${NC}"
    else
        echo -e "${RED}✗ Go not installed${NC}"
    fi

    echo ""
}

# Install Node.js and TypeScript environment
install_typescript() {
    echo -e "${YELLOW}📦 Installing TypeScript/Node.js environment...${NC}"

    local os=$(detect_os)

    if command_exists node; then
        echo -e "${GREEN}✓ Node.js already installed${NC}"
    else
        case $os in
            "linux")
                # Install Node.js via NodeSource repository
                curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - || \
                curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash - || \
                {
                    echo -e "${RED}Failed to add NodeSource repository${NC}"
                    return 1
                }

                if command_exists apt; then
                    sudo apt install -y nodejs
                elif command_exists yum; then
                    sudo yum install -y nodejs
                elif command_exists pacman; then
                    sudo pacman -S nodejs npm
                fi
                ;;
            "macos")
                brew install node
                ;;
        esac
    fi

    # Install global TypeScript tools
    if command_exists npm; then
        echo -e "${YELLOW}Installing global TypeScript tools...${NC}"
        npm install -g typescript ts-node @types/node
        echo -e "${GREEN}✓ TypeScript environment ready${NC}"
    fi
}

# Install Python environment
install_python() {
    echo -e "${YELLOW}📦 Installing Python environment...${NC}"

    local os=$(detect_os)

    if command_exists python3; then
        echo -e "${GREEN}✓ Python 3 already installed${NC}"
    else
        case $os in
            "linux")
                if command_exists apt; then
                    sudo apt install -y python3 python3-pip python3-venv python3-dev
                elif command_exists yum; then
                    sudo yum install -y python3 python3-pip python3-devel
                elif command_exists pacman; then
                    sudo pacman -S python python-pip
                fi
                ;;
            "macos")
                brew install python
                ;;
        esac
    fi

    # Install common Python tools
    if command_exists pip3; then
        echo -e "${YELLOW}Installing Python development tools...${NC}"
        pip3 install --user poetry pytest black mypy ruff
        echo -e "${GREEN}✓ Python environment ready${NC}"
    fi
}

# Install Julia environment
install_julia() {
    echo -e "${YELLOW}📦 Installing Julia environment...${NC}"

    if command_exists julia; then
        echo -e "${GREEN}✓ Julia already installed${NC}"
        return
    fi

    local os=$(detect_os)

    case $os in
        "linux")
            # Download and install Julia via juliaup
            curl -fsSL https://install.julialang.org | sh -s -- --yes
            source ~/.bashrc || true
            ;;
        "macos")
            # Install via Homebrew
            brew install julia
            ;;
    esac

    if command_exists julia; then
        echo -e "${GREEN}✓ Julia environment ready${NC}"
    else
        echo -e "${RED}✗ Julia installation failed${NC}"
        return 1
    fi
}

# Install Rust environment
install_rust() {
    echo -e "${YELLOW}📦 Installing Rust environment...${NC}"

    if command_exists cargo; then
        echo -e "${GREEN}✓ Rust already installed${NC}"
    else
        echo -e "${YELLOW}Installing Rust via rustup...${NC}"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source ~/.cargo/env || true
    fi

    # Install useful Rust tools
    if command_exists cargo; then
        echo -e "${YELLOW}Installing Rust development tools...${NC}"
        cargo install cargo-audit cargo-outdated || true
        echo -e "${GREEN}✓ Rust environment ready${NC}"
    fi
}

# Install Go environment
install_go() {
    echo -e "${YELLOW}📦 Installing Go environment...${NC}"

    if command_exists go; then
        echo -e "${GREEN}✓ Go already installed${NC}"
        return
    fi

    local os=$(detect_os)

    case $os in
        "linux")
            # Download and install Go
            local go_version="1.21.5"
            wget -qO- "https://golang.org/dl/go${go_version}.linux-amd64.tar.gz" | sudo tar -C /usr/local -xzf -

            # Add Go to PATH if not already there
            if ! grep -q "/usr/local/go/bin" ~/.bashrc; then
                echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
                echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> ~/.bashrc
            fi
            export PATH=$PATH:/usr/local/go/bin
            ;;
        "macos")
            brew install go
            ;;
    esac

    # Install useful Go tools
    if command_exists go; then
        echo -e "${YELLOW}Installing Go development tools...${NC}"
        go install golang.org/x/vuln/cmd/govulncheck@latest || true
        echo -e "${GREEN}✓ Go environment ready${NC}"
    fi
}

# Install development tools
install_dev_tools() {
    echo -e "${YELLOW}📦 Installing development tools...${NC}"

    local os=$(detect_os)

    # Install basic development tools
    case $os in
        "linux")
            if command_exists apt; then
                sudo apt install -y build-essential git curl wget jq tree htop
            elif command_exists yum; then
                sudo yum groupinstall -y "Development Tools"
                sudo yum install -y git curl wget jq tree htop
            elif command_exists pacman; then
                sudo pacman -S base-devel git curl wget jq tree htop
            fi
            ;;
        "macos")
            # Install Xcode command line tools
            xcode-select --install 2>/dev/null || true
            brew install git curl wget jq tree htop
            ;;
    esac

    echo -e "${GREEN}✓ Development tools installed${NC}"
}

# Setup workspace
setup_workspace() {
    echo -e "${BLUE}🏗️  Setting up workspace...${NC}"

    # Make scripts executable
    chmod +x scripts/deps
    chmod +x scripts/*.sh 2>/dev/null || true

    # Check workspace integrity
    if [[ -f "workspace.json" ]]; then
        echo -e "${GREEN}✓ workspace.json found${NC}"
    else
        echo -e "${RED}✗ workspace.json not found${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Workspace setup complete${NC}"
}

# Install all dependencies for existing packages
install_all_dependencies() {
    echo -e "${BLUE}📥 Installing all package dependencies...${NC}\n"

    # Use our dependency management system
    ./scripts/deps install

    echo -e "\n${GREEN}✓ All dependencies installed${NC}"
}

# Main installation process
main() {
    local install_all=false
    local install_typescript=false
    local install_python=false
    local install_julia=false
    local install_rust=false
    local install_go=false
    local install_dev=false
    local check_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                install_all=true
                shift
                ;;
            --typescript|--ts)
                install_typescript=true
                shift
                ;;
            --python|--py)
                install_python=true
                shift
                ;;
            --julia|--jl)
                install_julia=true
                shift
                ;;
            --rust|--rs)
                install_rust=true
                shift
                ;;
            --go|--golang)
                install_go=true
                shift
                ;;
            --dev)
                install_dev=true
                shift
                ;;
            --check)
                check_only=true
                shift
                ;;
            --help|-h)
                print_help
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                print_help
                exit 1
                ;;
        esac
    done

    print_header

    # If no specific options, show help
    if [[ $install_all == false && $install_typescript == false && $install_python == false &&
          $install_julia == false && $install_rust == false && $install_go == false &&
          $install_dev == false && $check_only == false ]]; then
        print_help
        exit 0
    fi

    # Set install_all flags
    if [[ $install_all == true ]]; then
        install_typescript=true
        install_python=true
        install_julia=true
        install_rust=true
        install_go=true
        install_dev=true
    fi

    # Always check requirements first
    if ! check_requirements; then
        echo -e "${RED}System requirements not met. Please install missing requirements.${NC}"
        exit 1
    fi

    check_languages

    if [[ $check_only == true ]]; then
        echo -e "${BLUE}Check complete. Use --all to install everything or specific flags for individual languages.${NC}"
        exit 0
    fi

    # Install package manager if needed
    install_package_manager

    # Install requested environments
    if [[ $install_typescript == true ]]; then
        install_typescript
    fi

    if [[ $install_python == true ]]; then
        install_python
    fi

    if [[ $install_julia == true ]]; then
        install_julia
    fi

    if [[ $install_rust == true ]]; then
        install_rust
    fi

    if [[ $install_go == true ]]; then
        install_go
    fi

    if [[ $install_dev == true ]]; then
        install_dev_tools
    fi

    # Setup workspace
    setup_workspace

    # Install package dependencies
    if [[ $install_all == true ]] || [[ $install_typescript == true ]] || [[ $install_python == true ]] ||
       [[ $install_julia == true ]] || [[ $install_rust == true ]] || [[ $install_go == true ]]; then
        install_all_dependencies
    fi

    echo ""
    echo -e "${GREEN}🎉 Installation complete!${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Restart your shell or run: source ~/.bashrc"
    echo "  2. Run './scripts/deps check' to verify all dependencies"
    echo "  3. Run './scripts/deps report' to generate a full dependency report"
    echo ""
    echo -e "${CYAN}Useful commands:${NC}"
    echo "  ./scripts/deps list      # List all packages"
    echo "  ./scripts/deps check     # Check for dependency conflicts"
    echo "  ./scripts/deps update    # Update all dependencies"
    echo ""
}

main "$@"