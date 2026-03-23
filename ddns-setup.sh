	#!/bin/bash
	#===============================================================================
	# DDNS Server Setup Script
	#===============================================================================
	# Version: 1.0.0
	# Author: SuperNinja AI Agent
	# Description: Production-ready Dynamic DNS server deployment with web interface
	# License: MIT
	# 
	# Features:
	#   - User authentication with email verification
	#   - Subdomain management (one per user)
	#   - IPv4 and IPv6 support
	#   - Admin panel with full control
	#   - IONOS API integration for DNS management
	#   - Let's Encrypt SSL
	#   - SQLite3 database with encryption support
	#
	# Usage: sudo ./ddns-setup.sh
	#
	# Requirements:
	#   - Ubuntu 20.04 LTS or newer / Debian-based Linux
	#   - Root or sudo privileges
	#   - Domain pointed to this server's IP
	#
	# Security Warnings:
	#   ⚠️  CHANGE DEFAULT ADMIN PASSWORD IMMEDIATELY AFTER INSTALLATION
	#   ⚠️  ROTATE DATABASE ENCRYPTION KEY BEFORE PRODUCTION USE
	#   ⚠️  SECURE IONOS API CREDENTIALS
	#   ⚠️  ENABLE REGULAR SECURITY UPDATES
	#===============================================================================

	set -e  # Exit on error (will be handled by trap)

	#-------------------------------------------------------------------------------
	# Script Configuration
	#-------------------------------------------------------------------------------
	readonly SCRIPT_VERSION="1.0.0"
	readonly SCRIPT_NAME=$(basename "$0")
	readonly LOG_FILE="/var/log/rslvd-setup.log"
	readonly LOCK_FILE="/var/run/ddns-setup.lock"

	# Domain Configuration
	DOMAIN="rslvd.net"
	WEB_ROOT="/var/www/rslvd.net"
	DB_PATH="${WEB_ROOT}/data/rslvd.db"
	DB_ENCRYPTION_KEY="Zxcv1989"

	# Admin Configuration (MUST BE CHANGED AFTER INSTALLATION)
	DEFAULT_ADMIN_EMAIL="admin@rslvd.net"
	DEFAULT_ADMIN_PASSWORD="Zxcv1989"

	# IONOS API Configuration
	IONOS_API_KEY=""
	IONOS_API_URL="https://api.hosting.ionos.com/dns/v1"

	# Colors for output
	readonly RED='\033[0;31m'
	readonly GREEN='\033[0;32m'
	readonly YELLOW='\033[1;33m'
	readonly BLUE='\033[0;34m'
	readonly PURPLE='\033[0;35m'
	readonly CYAN='\033[0;36m'
	readonly NC='\033[0m' # No Color
	readonly BOLD='\033[1m'

	# Animation frames for progress indicator
	readonly SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

	# Track installation steps for rollback
	declare -a COMPLETED_STEPS=()

	#-------------------------------------------------------------------------------
	# Utility Functions
	#-------------------------------------------------------------------------------

	# Initialize logging
	init_logging() {
		mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
		touch "$LOG_FILE" 2>/dev/null || true
		chmod 644 "$LOG_FILE" 2>/dev/null || true
		log_message "INFO" "=== DDNS Setup Script v${SCRIPT_VERSION} Started ==="
	}

	# Log messages to file
	log_message() {
		local level="$1"
		local message="$2"
		local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
		echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
	}

	# Print colored status messages
	print_status() {
		local type="$1"
		local message="$2"
		local prefix=""
		
		case "$type" in
			"success")
				prefix="${GREEN}✓${NC}"
				log_message "SUCCESS" "$message"
				;;
			"error")
				prefix="${RED}✗${NC}"
				log_message "ERROR" "$message"
				;;
			"warning")
				prefix="${YELLOW}⚠${NC}"
				log_message "WARNING" "$message"
				;;
			"info")
				prefix="${BLUE}ℹ${NC}"
				log_message "INFO" "$message"
				;;
			"step")
				prefix="${PURPLE}►${NC}"
				log_message "STEP" "$message"
				;;
			"header")
				echo ""
				echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
				echo -e "${BOLD}${CYAN}  $message${NC}"
				echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
				echo ""
				log_message "HEADER" "$message"
				return
				;;
		esac
		
		echo -e "$prefix $message"
	}

	# Print a progress bar
	print_progress() {
		local current=$1
		local total=$2
		local width=50
		local percent=$((current * 100 / total))
		local filled=$((current * width / total))
		local empty=$((width - filled))
		
		printf "\r${CYAN}Progress: [${GREEN}"
		printf "%${filled}s" | tr ' ' '█'
		printf "${CYAN}"
		printf "%${empty}s" | tr ' ' '░'
		printf "] ${percent}%%${NC}"
	}

	# Spinner animation for long operations
	show_spinner() {
		local pid=$1
		local message="$2"
		local i=0
		
		while kill -0 $pid 2>/dev/null; do
			printf "\r${CYAN}${SPINNER[$((i % 10))]}${NC} $message"
			i=$((i + 1))
			sleep 0.1
		done
		
		printf "\r%${#message}s\r" ""
	}

	# Confirm action with user
	confirm_action() {
		local message="$1"
		local default="${2:-n}"
		
		if [[ "$default" == "y" ]]; then
			prompt="Y/n"
		else
			prompt="y/N"
		fi
		
		echo -en "${YELLOW}?${NC} $message [$prompt]: "
		read -r response
		
		case "$response" in
			[yY][eE][sS]|[yY]) return 0 ;;
			[nN][oO]|[nN]) return 1 ;;
			*) [[ "$default" == "y" ]] && return 0 || return 1 ;;
		esac
	}

	# Get user input with default value
	get_input() {
		local message="$1"
		local default="$2"
		local result=""
		
		if [[ -n "$default" ]]; then
			echo -en "${YELLOW}?${NC} $message [$default]: "
		else
			echo -en "${YELLOW}?${NC} $message: "
		fi
		
		read -r result
		
		if [[ -z "$result" && -n "$default" ]]; then
			echo "$default"
		else
			echo "$result"
		fi
	}

	# Error handler with rollback
	error_handler() {
		local exit_code=$?
		local line_number=$1
		
		print_status "error" "Script failed at line $line_number with exit code $exit_code"
		
		# Ask for rollback
		if [[ ${#COMPLETED_STEPS[@]} -gt 0 ]]; then
			if confirm_action "Would you like to rollback completed steps?" "n"; then
				perform_rollback
			fi
		fi
		
		# Remove lock file
		rm -f "$LOCK_FILE" 2>/dev/null || true
		
		print_status "error" "Installation failed. Check $LOG_FILE for details."
		exit $exit_code
	}

	# Perform rollback of completed steps
	perform_rollback() {
		print_status "warning" "Initiating rollback..."
		
		# Reverse the completed steps array
		local reversed=()
		for ((i=${#COMPLETED_STEPS[@]}-1; i>=0; i--)); do
			reversed+=("${COMPLETED_STEPS[$i]}")
		done
		
		for step in "${reversed[@]}"; do
			case "$step" in
				"ssl")
					print_status "info" "Removing SSL certificate..."
					certbot revoke --cert-path "/etc/letsencrypt/live/$DOMAIN/cert.pem" --non-interactive 2>/dev/null || true
					;;
				"apache")
					print_status "info" "Removing Apache configuration..."
					a2dissite "$DOMAIN" 2>/dev/null || true
					rm -f "/etc/apache2/sites-available/$DOMAIN.conf"
					systemctl reload apache2 2>/dev/null || true
					;;
				"database")
					print_status "info" "Removing database..."
					rm -f "$DB_PATH" 2>/dev/null || true
					;;
				"directories")
					print_status "info" "Removing directories..."
					rm -rf "$WEB_ROOT" 2>/dev/null || true
					;;
				"packages")
					print_status "info" "Note: Installed packages not removed. Run 'apt remove' manually if needed."
					;;
			esac
		done
		
		print_status "success" "Rollback completed"
	}

	# Trap for error handling
	trap 'error_handler $LINENO' ERR
	trap 'rm -f "$LOCK_FILE" 2>/dev/null' EXIT

	#-------------------------------------------------------------------------------
	# Core Functions
	#-------------------------------------------------------------------------------

	# Check if running as root
	check_root() {
		print_status "step" "Checking root privileges..."
		
		if [[ $EUID -ne 0 ]]; then
			print_status "error" "This script must be run as root or with sudo"
			print_status "info" "Usage: sudo $SCRIPT_NAME"
			exit 1
		fi
		
		print_status "success" "Running with root privileges"
	}

	# Check for lock file to prevent concurrent runs
	check_lock() {
		if [[ -f "$LOCK_FILE" ]]; then
			print_status "error" "Another instance is already running"
			print_status "info" "If you're sure no other instance is running, remove $LOCK_FILE"
			exit 1
		fi
		
		echo $$ > "$LOCK_FILE"
	}

	# Check existing dependencies
	check_dependencies() {
		print_status "step" "Checking existing dependencies..."
		
		local required_packages=("curl" "wget" "openssl")
		local missing=()
		
		for pkg in "${required_packages[@]}"; do
			if ! command -v "$pkg" &> /dev/null; then
				missing+=("$pkg")
			fi
		done
		
		if [[ ${#missing[@]} -gt 0 ]]; then
			print_status "warning" "Missing packages: ${missing[*]}"
			print_status "info" "Installing missing prerequisites..."
			apt-get update -qq
			apt-get install -y -qq "${missing[@]}"
		fi
		
		print_status "success" "All prerequisites satisfied"
	}

	# Install required packages
	install_dependencies() {
		print_status "header" "Installing System Dependencies"
		
		local packages=(
			"apache2"
			"php7.4"
			"php7.4-sqlite3"
			"php7.4-curl"
			"php7.4-mbstring"
			"php7.4-xml"
			"php7.4-intl"
			"php7.4-json"
			"sqlite3"
			"certbot"
			"python3-certbot-apache"
			"sendmail"
			"mailutils"
			"jq"
			"ufw"
		)
		
		# Check if packages are already installed
		local to_install=()
		for pkg in "${packages[@]}"; do
			if ! dpkg -l | grep -q "^ii  $pkg"; then
				to_install+=("$pkg")
			fi
		done
		
		if [[ ${#to_install[@]} -eq 0 ]]; then
			print_status "success" "All required packages are already installed"
			COMPLETED_STEPS+=("packages")
			return 0
		fi
		
		print_status "info" "Packages to install: ${to_install[*]}"
		
		# Update package list with spinner
		print_status "info" "Updating package list..."
		apt-get update -qq &
		show_spinner $! "Updating package list..."
		
		# Install packages
		print_status "info" "Installing packages (this may take a few minutes)..."
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}" &
		show_spinner $! "Installing packages..."
		
		# Verify installation
		local failed=()
		for pkg in "${packages[@]}"; do
			if ! dpkg -l | grep -q "^ii  $pkg"; then
				failed+=("$pkg")
			fi
		done
		
		if [[ ${#failed[@]} -gt 0 ]]; then
			print_status "error" "Failed to install: ${failed[*]}"
			return 1
		fi
		
		print_status "success" "All packages installed successfully"
		COMPLETED_STEPS+=("packages")
	}

	# Create directory structure
	create_directory_structure() {
		print_status "header" "Creating Directory Structure"
		
		local directories=(
			"$WEB_ROOT"
			"$WEB_ROOT/public"
			"$WEB_ROOT/public/css"
			"$WEB_ROOT/public/js"
			"$WEB_ROOT/public/images"
			"$WEB_ROOT/data"
			"$WEB_ROOT/logs"
			"$WEB_ROOT/includes"
			"$WEB_ROOT/includes/classes"
			"$WEB_ROOT/includes/functions"
			"$WEB_ROOT/admin"
			"$WEB_ROOT/api"
			"$WEB_ROOT/templates"
			"$WEB_ROOT/tmp"
		)
		
		for dir in "${directories[@]}"; do
			if [[ ! -d "$dir" ]]; then
				print_status "info" "Creating: $dir"
				mkdir -p "$dir"
			else
				print_status "info" "Exists: $dir"
			fi
		done
		
		print_status "success" "Directory structure created"
		COMPLETED_STEPS+=("directories")
	}

	#-------------------------------------------------------------------------------
	# Database Setup
	#-------------------------------------------------------------------------------

	# Initialize SQLite database with schema
	setup_database() {
		print_status "header" "Setting Up Database"
		
		# Check if database already exists
		if [[ -f "$DB_PATH" ]]; then
			if ! confirm_action "Database already exists. Recreate?" "n"; then
				print_status "info" "Keeping existing database"
				return 0
			fi
			print_status "warning" "Backing up existing database..."
			cp "$DB_PATH" "${DB_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
			rm -f "$DB_PATH"
		fi
		
		print_status "info" "Creating database schema..."
		
		# Create database schema
		sqlite3 "$DB_PATH" << 'EOF'
	-- Users table
	CREATE TABLE IF NOT EXISTS users (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		email TEXT UNIQUE NOT NULL,
		password_hash TEXT NOT NULL,
		email_verified INTEGER DEFAULT 0,
		verification_token TEXT,
		api_token TEXT UNIQUE,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		last_login DATETIME,
		failed_login_attempts INTEGER DEFAULT 0,
		lockout_until DATETIME
	);

	-- Subdomains table
	CREATE TABLE IF NOT EXISTS subdomains (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER NOT NULL,
		subdomain_name TEXT UNIQUE NOT NULL,
		current_ipv4 TEXT,
		current_ipv6 TEXT,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		updated_at DATETIME,
		active INTEGER DEFAULT 1,
		FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
	);

	-- Admins table
	CREATE TABLE IF NOT EXISTS admins (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		email TEXT UNIQUE NOT NULL,
		password_hash TEXT NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		last_login DATETIME
	);

	-- Update logs table
	CREATE TABLE IF NOT EXISTS update_logs (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		subdomain_id INTEGER NOT NULL,
		old_ipv4 TEXT,
		new_ipv4 TEXT,
		old_ipv6 TEXT,
		new_ipv6 TEXT,
		ip_type TEXT CHECK(ip_type IN ('ipv4', 'ipv6', 'both')),
		updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY (subdomain_id) REFERENCES subdomains(id) ON DELETE CASCADE
	);

	-- Admin activity logs table
	CREATE TABLE IF NOT EXISTS admin_logs (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		admin_id INTEGER NOT NULL,
		action TEXT NOT NULL,
		target_type TEXT,
		target_id INTEGER,
		details TEXT,
		ip_address TEXT,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY (admin_id) REFERENCES admins(id) ON DELETE CASCADE
	);

	-- Sessions table for session management
	CREATE TABLE IF NOT EXISTS sessions (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER,
		admin_id INTEGER,
		session_token TEXT UNIQUE NOT NULL,
		csrf_token TEXT,
		ip_address TEXT,
		user_agent TEXT,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		expires_at DATETIME,
		FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
		FOREIGN KEY (admin_id) REFERENCES admins(id) ON DELETE CASCADE
	);

	-- Rate limiting table
	CREATE TABLE IF NOT EXISTS rate_limits (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		ip_address TEXT NOT NULL,
		action_type TEXT NOT NULL,
		attempt_count INTEGER DEFAULT 1,
		first_attempt DATETIME DEFAULT CURRENT_TIMESTAMP,
		last_attempt DATETIME DEFAULT CURRENT_TIMESTAMP
	);

	-- Create indexes
	CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
	CREATE INDEX IF NOT EXISTS idx_users_api_token ON users(api_token);
	CREATE INDEX IF NOT EXISTS idx_subdomains_name ON subdomains(subdomain_name);
	CREATE INDEX IF NOT EXISTS idx_subdomains_user_id ON subdomains(user_id);
	CREATE INDEX IF NOT EXISTS idx_update_logs_subdomain_id ON update_logs(subdomain_id);
	CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(session_token);
	CREATE INDEX IF NOT EXISTS idx_rate_limits_ip_action ON rate_limits(ip_address, action_type);
	EOF
		
		if [[ $? -ne 0 ]]; then
			print_status "error" "Failed to create database schema"
			return 1
		fi
		
		print_status "success" "Database schema created"
		
		# Create default admin account
		print_status "info" "Creating default admin account..."
		
		local admin_password_hash
		admin_password_hash=$(php -r "echo password_hash('$DEFAULT_ADMIN_PASSWORD', PASSWORD_BCRYPT, ['cost' => 12]);")
		
		sqlite3 "$DB_PATH" "INSERT INTO admins (email, password_hash) VALUES ('$DEFAULT_ADMIN_EMAIL', '$admin_password_hash');"
		
		if [[ $? -eq 0 ]]; then
			print_status "success" "Admin account created"
			print_status "warning" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
			print_status "warning" "  IMPORTANT: Change the default admin password immediately!"
			print_status "warning" "  Email: $DEFAULT_ADMIN_EMAIL"
			print_status "warning" "  Password: [DEFAULT_PASSWORD_SET]"
			print_status "warning" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
		else
			print_status "error" "Failed to create admin account"
			return 1
		fi
		
		COMPLETED_STEPS+=("database")
	}

	#-------------------------------------------------------------------------------
	# PHP Backend Files
	#-------------------------------------------------------------------------------

	# Create PHP configuration file
	create_php_config() {
		print_status "info" "Creating PHP configuration..."
		
		cat > "$WEB_ROOT/includes/config.php" << PHPEOF
	<?php
	/**
	 * DDNS Server Configuration
	 * 
	 * ⚠️  SECURITY WARNING: This file contains sensitive configuration.
	 *    - Change the encryption key before production use
	 *    - Protect database credentials
	 *    - Keep this file outside web root if possible
	 */

	// Prevent direct access
	if (!defined('APP_ROOT')) {
		die('Direct access denied');
	}

	// Application version
	define('APP_VERSION', '1.0.0');

	// Paths
	define('DB_PATH', '$DB_PATH');
	define('LOG_PATH', '$WEB_ROOT/logs');
	define('TMP_PATH', '$WEB_ROOT/tmp');
	define('INCLUDES_PATH', '$WEB_ROOT/includes');
	define('TEMPLATES_PATH', '$WEB_ROOT/templates');

	// Database configuration
	define('DB_ENCRYPTION_KEY', '$DB_ENCRYPTION_KEY');

	// Domain settings
	define('DOMAIN', '$DOMAIN');
	define('BASE_URL', 'https://' . DOMAIN);

	// Session configuration
	define('SESSION_NAME', 'DDNS_SESSION');
	define('SESSION_LIFETIME', 86400); // 24 hours
	define('SESSION_SECURE', true);
	define('SESSION_HTTPONLY', true);
	define('SESSION_SAMESITE', 'Strict');

	// Password requirements
	define('PASSWORD_MIN_LENGTH', 8);
	define('PASSWORD_REQUIRE_UPPERCASE', true);
	define('PASSWORD_REQUIRE_LOWERCASE', true);
	define('PASSWORD_REQUIRE_NUMBER', true);
	define('PASSWORD_REQUIRE_SPECIAL', false);
	define('PASSWORD_HASH_COST', 12);

	// Rate limiting
	define('RATE_LIMIT_MAX_ATTEMPTS', 5);
	define('RATE_LIMIT_WINDOW', 900); // 15 minutes in seconds
	define('RATE_LIMIT_LOCKOUT', 1800); // 30 minutes in seconds

	// Subdomain rules
	define('SUBDOMAIN_MIN_LENGTH', 3);
	define('SUBDOMAIN_MAX_LENGTH', 63);

	// API configuration
	define('API_TOKEN_LENGTH', 32);

	// Email settings (configure for your SMTP server)
	define('EMAIL_FROM', 'noreply@$DOMAIN');
	define('EMAIL_FROM_NAME', 'DDNS Service');
	define('EMAIL_VERIFICATION_EXPIRY', 86400); // 24 hours

	// IONOS API configuration
	define('IONOS_API_URL', 'https://api.hosting.ionos.com/dns/v1');

	// Security settings
	define('CSRF_TOKEN_EXPIRY', 3600); // 1 hour
	define('REMEMBER_ME_DAYS', 30);

	// Timezone
	date_default_timezone_set('UTC');

	// Error reporting (disable in production)
	if (getenv('APP_ENV') === 'development') {
		error_reporting(E_ALL);
		ini_set('display_errors', '1');
	} else {
		error_reporting(0);
		ini_set('display_errors', '0');
	}

	// Autoload classes
	spl_autoload_register(function (\$class) {
		\$file = INCLUDES_PATH . '/classes/' . str_replace('\\\\', '/', \$class) . '.php';
		if (file_exists(\$file)) {
			require_once \$file;
		}
	});
	PHPEOF
	}

	# Create database class
	create_database_class() {
		print_status "info" "Creating database class..."
		
		cat > "$WEB_ROOT/includes/classes/Database.php" << 'PHPEOF'
	<?php
	/**
	 * Database Handler Class
	 * 
	 * Provides secure database operations with prepared statements
	 * and automatic error handling.
	 */

	class Database
	{
		private static ?PDO $instance = null;
		private PDO $connection;
		
		/**
		 * Private constructor for singleton pattern
		 */
		private function __construct()
		{
			try {
				$dsn = 'sqlite:' . DB_PATH;
				$options = [
					PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
					PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
					PDO::ATTR_EMULATE_PREPARES => false,
				];
				
				$this->connection = new PDO($dsn, null, null, $options);
				
				// Enable foreign keys
				$this->connection->exec('PRAGMA foreign_keys = ON;');
				
				// Enable WAL mode for better concurrency
				$this->connection->exec('PRAGMA journal_mode = WAL;');
				
			} catch (PDOException $e) {
				$this->logError('Connection failed: ' . $e->getMessage());
				throw new Exception('Database connection failed');
			}
		}
		
		/**
		 * Get singleton instance
		 */
		public static function getInstance(): self
		{
			if (self::$instance === null) {
				self::$instance = new self();
			}
			return self::$instance;
		}
		
		/**
		 * Get PDO connection
		 */
		public function getConnection(): PDO
		{
			return $this->connection;
		}
		
		/**
		 * Execute a prepared statement
		 */
		public function query(string $sql, array $params = []): PDOStatement
		{
			try {
				$stmt = $this->connection->prepare($sql);
				$stmt->execute($params);
				return $stmt;
			} catch (PDOException $e) {
				$this->logError("Query failed: {$e->getMessage()} | SQL: $sql");
				throw $e;
			}
		}
		
		/**
		 * Execute a query and return all rows
		 */
		public function fetchAll(string $sql, array $params = []): array
		{
			return $this->query($sql, $params)->fetchAll();
		}
		
		/**
		 * Execute a query and return a single row
		 */
		public function fetchOne(string $sql, array $params = []): ?array
		{
			$result = $this->query($sql, $params)->fetch();
			return $result ?: null;
		}
		
		/**
		 * Execute a query and return a single column
		 */
		public function fetchColumn(string $sql, array $params = [], int $column = 0)
		{
			return $this->query($sql, $params)->fetchColumn($column);
		}
		
		/**
		 * Insert a row and return the last insert ID
		 */
		public function insert(string $table, array $data): int
		{
			$columns = implode(', ', array_keys($data));
			$placeholders = implode(', ', array_fill(0, count($data), '?'));
			
			$sql = "INSERT INTO $table ($columns) VALUES ($placeholders)";
			$this->query($sql, array_values($data));
			
			return (int) $this->connection->lastInsertId();
		}
		
		/**
		 * Update rows and return affected count
		 */
		public function update(string $table, array $data, string $where, array $whereParams = []): int
		{
			$setClauses = [];
			foreach (array_keys($data) as $column) {
				$setClauses[] = "$column = ?";
			}
			
			$sql = "UPDATE $table SET " . implode(', ', $setClauses) . " WHERE $where";
			$stmt = $this->query($sql, array_merge(array_values($data), $whereParams));
			
			return $stmt->rowCount();
		}
		
		/**
		 * Delete rows and return affected count
		 */
		public function delete(string $table, string $where, array $params = []): int
		{
			$sql = "DELETE FROM $table WHERE $where";
			$stmt = $this->query($sql, $params);
			return $stmt->rowCount();
		}
		
		/**
		 * Begin a transaction
		 */
		public function beginTransaction(): bool
		{
			return $this->connection->beginTransaction();
		}
		
		/**
		 * Commit a transaction
		 */
		public function commit(): bool
		{
			return $this->connection->commit();
		}
		
		/**
		 * Rollback a transaction
		 */
		public function rollback(): bool
		{
			return $this->connection->rollBack();
		}
		
		/**
		 * Check if in transaction
		 */
		public function inTransaction(): bool
		{
			return $this->connection->inTransaction();
		}
		
		/**
		 * Get row count
		 */
		public function count(string $table, string $where = '1=1', array $params = []): int
		{
			$sql = "SELECT COUNT(*) FROM $table WHERE $where";
			return (int) $this->fetchColumn($sql, $params);
		}
		
		/**
		 * Check if row exists
		 */
		public function exists(string $table, string $where, array $params = []): bool
		{
			return $this->count($table, $where, $params) > 0;
		}
		
		/**
		 * Log database errors
		 */
		private function logError(string $message): void
		{
			$logFile = LOG_PATH . '/database.log';
			$timestamp = date('Y-m-d H:i:s');
			file_put_contents($logFile, "[$timestamp] ERROR: $message\n", FILE_APPEND);
		}
		
		/**
		 * Prevent cloning
		 */
		private function __clone() {}
		
		/**
		 * Prevent unserialization
		 */
		public function __wakeup()
		{
			throw new Exception('Cannot unserialize singleton');
		}
	}
	PHPEOF
	}

	# Create security functions
	create_security_functions() {
		print_status "info" "Creating security functions..."
		
		cat > "$WEB_ROOT/includes/functions/security.php" << 'PHPEOF'
	<?php
	/**
	 * Security Functions
	 * 
	 * Provides CSRF protection, XSS prevention, and input sanitization
	 */

	/**
	 * Generate a CSRF token
	 */
	function generateCsrfToken(): string
	{
		if (!isset($_SESSION['csrf_token'])) {
			$_SESSION['csrf_token'] = bin2hex(random_bytes(32));
			$_SESSION['csrf_token_time'] = time();
		}
		return $_SESSION['csrf_token'];
	}

	/**
	 * Validate a CSRF token
	 */
	function validateCsrfToken(?string $token): bool
	{
		if (!isset($_SESSION['csrf_token'], $_SESSION['csrf_token_time'])) {
			return false;
		}
		
		// Check token expiry
		if (time() - $_SESSION['csrf_token_time'] > CSRF_TOKEN_EXPIRY) {
			unset($_SESSION['csrf_token'], $_SESSION['csrf_token_time']);
			return false;
		}
		
		return hash_equals($_SESSION['csrf_token'], $token ?? '');
	}

	/**
	 * Get CSRF token field for forms
	 */
	function csrfField(): string
	{
		$token = generateCsrfToken();
		return '<input type="hidden" name="csrf_token" value="' . htmlspecialchars($token) . '">';
	}

	/**
	 * Sanitize output for HTML
	 */
	function h(string $string): string
	{
		return htmlspecialchars($string, ENT_QUOTES | ENT_HTML5, 'UTF-8');
	}

	/**
	 * Sanitize input string
	 */
	function sanitizeInput(string $input): string
	{
		$input = trim($input);
		$input = stripslashes($input);
		return $input;
	}

	/**
	 * Validate email address
	 */
	function validateEmail(string $email): bool
	{
		return filter_var($email, FILTER_VALIDATE_EMAIL) !== false;
	}

	/**
	 * Validate subdomain name
	 */
	function validateSubdomain(string $subdomain): array
	{
		$errors = [];
		$length = strlen($subdomain);
		
		if ($length < SUBDOMAIN_MIN_LENGTH) {
			$errors[] = "Subdomain must be at least " . SUBDOMAIN_MIN_LENGTH . " characters";
		}
		
		if ($length > SUBDOMAIN_MAX_LENGTH) {
			$errors[] = "Subdomain must be no more than " . SUBDOMAIN_MAX_LENGTH . " characters";
		}
		
		if (!preg_match('/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/', strtolower($subdomain))) {
			$errors[] = "Subdomain can only contain lowercase letters, numbers, and hyphens";
			$errors[] = "Subdomain cannot start or end with a hyphen";
		}
		
		// Reserved subdomains
		$reserved = ['www', 'mail', 'ftp', 'smtp', 'pop', 'imap', 'admin', 'api', 
					 'ns1', 'ns2', 'dns', 'dev', 'staging', 'test', 'localhost'];
		
		if (in_array(strtolower($subdomain), $reserved)) {
			$errors[] = "This subdomain is reserved and cannot be used";
		}
		
		return $errors;
	}

	/**
	 * Validate password strength
	 */
	function validatePassword(string $password): array
	{
		$errors = [];
		
		if (strlen($password) < PASSWORD_MIN_LENGTH) {
			$errors[] = "Password must be at least " . PASSWORD_MIN_LENGTH . " characters";
		}
		
		if (PASSWORD_REQUIRE_UPPERCASE && !preg_match('/[A-Z]/', $password)) {
			$errors[] = "Password must contain at least one uppercase letter";
		}
		
		if (PASSWORD_REQUIRE_LOWERCASE && !preg_match('/[a-z]/', $password)) {
			$errors[] = "Password must contain at least one lowercase letter";
		}
		
		if (PASSWORD_REQUIRE_NUMBER && !preg_match('/[0-9]/', $password)) {
			$errors[] = "Password must contain at least one number";
		}
		
		if (PASSWORD_REQUIRE_SPECIAL && !preg_match('/[!@#$%^&*(),.?":{}|<>]/', $password)) {
			$errors[] = "Password must contain at least one special character";
		}
		
		return $errors;
	}

	/**
	 * Hash a password
	 */
	function hashPassword(string $password): string
	{
		return password_hash($password, PASSWORD_BCRYPT, ['cost' => PASSWORD_HASH_COST]);
	}

	/**
	 * Verify a password
	 */
	function verifyPassword(string $password, string $hash): bool
	{
		return password_verify($password, $hash);
	}

	/**
	 * Generate a secure random token
	 */
	function generateToken(int $length = 32): string
	{
		return bin2hex(random_bytes($length));
	}

	/**
	 * Generate API token
	 */
	function generateApiToken(): string
	{
		return 'ddns_' . bin2hex(random_bytes(API_TOKEN_LENGTH));
	}

	/**
	 * Validate IPv4 address
	 */
	function validateIPv4(string $ip): bool
	{
		return filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false;
	}

	/**
	 * Validate IPv6 address
	 */
	function validateIPv6(string $ip): bool
	{
		return filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false;
	}

	/**
	 * Get client IP address
	 */
	function getClientIp(): string
	{
		$headers = [
			'HTTP_CF_CONNECTING_IP',     // Cloudflare
			'HTTP_X_FORWARDED_FOR',       // General proxy
			'HTTP_X_REAL_IP',             // Nginx
			'HTTP_CLIENT_IP',             // General
		];
		
		foreach ($headers as $header) {
			if (!empty($_SERVER[$header])) {
				$ip = $_SERVER[$header];
				if (strpos($ip, ',') !== false) {
					$ip = trim(explode(',', $ip)[0]);
				}
				if (validateIPv4($ip) || validateIPv6($ip)) {
					return $ip;
				}
			}
		}
		
		return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
	}

	/**
	 * Set security headers
	 */
	function setSecurityHeaders(): void
	{
		header('X-Frame-Options: DENY');
		header('X-Content-Type-Options: nosniff');
		header('X-XSS-Protection: 1; mode=block');
		header('Referrer-Policy: strict-origin-when-cross-origin');
		header('Permissions-Policy: geolocation=(), microphone=(), camera=()');
		
		// Content Security Policy
		$csp = "default-src 'self'; ";
		$csp .= "script-src 'self' 'unsafe-inline'; ";
		$csp .= "style-src 'self' 'unsafe-inline'; ";
		$csp .= "img-src 'self' data:; ";
		$csp .= "font-src 'self'; ";
		$csp .= "connect-src 'self'; ";
		$csp .= "frame-ancestors 'none';";
		
		header("Content-Security-Policy: $csp");
	}

	/**
	 * Rate limit check
	 */
	function checkRateLimit(string $action, ?string $ip = null): array
	{
		$ip = $ip ?? getClientIp();
		$db = Database::getInstance();
		
		// Clean old entries
		$cutoff = date('Y-m-d H:i:s', time() - RATE_LIMIT_WINDOW);
		$db->delete('rate_limits', 'last_attempt < ?', [$cutoff]);
		
		// Get current attempts
		$record = $db->fetchOne(
			"SELECT * FROM rate_limits WHERE ip_address = ? AND action_type = ?",
			[$ip, $action]
		);
		
		if (!$record) {
			return ['allowed' => true, 'attempts' => 0, 'remaining' => RATE_LIMIT_MAX_ATTEMPTS];
		}
		
		if ($record['attempt_count'] >= RATE_LIMIT_MAX_ATTEMPTS) {
			return ['allowed' => false, 'attempts' => $record['attempt_count'], 'remaining' => 0];
		}
		
		return [
			'allowed' => true, 
			'attempts' => $record['attempt_count'], 
			'remaining' => RATE_LIMIT_MAX_ATTEMPTS - $record['attempt_count']
		];
	}

	/**
	 * Record rate limit attempt
	 */
	function recordRateLimitAttempt(string $action, ?string $ip = null): void
	{
		$ip = $ip ?? getClientIp();
		$db = Database::getInstance();
		
		$existing = $db->fetchOne(
			"SELECT id, attempt_count FROM rate_limits WHERE ip_address = ? AND action_type = ?",
			[$ip, $action]
		);
		
		if ($existing) {
			$db->update('rate_limits', 
				['attempt_count' => $existing['attempt_count'] + 1, 'last_attempt' => date('Y-m-d H:i:s')],
				'id = ?',
				[$existing['id']]
			);
		} else {
			$db->insert('rate_limits', [
				'ip_address' => $ip,
				'action_type' => $action,
				'attempt_count' => 1
			]);
		}
	}

	/**
	 * Clear rate limit for an IP/action
	 */
	function clearRateLimit(string $action, ?string $ip = null): void
	{
		$ip = $ip ?? getClientIp();
		$db = Database::getInstance();
		$db->delete('rate_limits', 'ip_address = ? AND action_type = ?', [$ip, $action]);
	}
	PHPEOF
	}

	# Create session management
	create_session_functions() {
		print_status "info" "Creating session functions..."
		
		cat > "$WEB_ROOT/includes/functions/session.php" << 'PHPEOF'
	<?php
	/**
	 * Session Management Functions
	 */

	/**
	 * Start a secure session
	 */
	function startSecureSession(): void
	{
		if (session_status() === PHP_SESSION_ACTIVE) {
			return;
		}
		
		// Set session cookie parameters
		session_set_cookie_params([
			'lifetime' => SESSION_LIFETIME,
			'path' => '/',
			'domain' => '.' . DOMAIN,
			'secure' => SESSION_SECURE,
			'httponly' => SESSION_HTTPONLY,
			'samesite' => SESSION_SAMESITE
		]);
		
		session_name(SESSION_NAME);
		session_start();
		
		// Regenerate ID periodically to prevent session fixation
		if (!isset($_SESSION['created'])) {
			$_SESSION['created'] = time();
		} else if (time() - $_SESSION['created'] > 1800) { // 30 minutes
			session_regenerate_id(true);
			$_SESSION['created'] = time();
		}
	}

	/**
	 * Check if user is logged in
	 */
	function isLoggedIn(): bool
	{
		return isset($_SESSION['user_id']) && !empty($_SESSION['user_id']);
	}

	/**
	 * Check if admin is logged in
	 */
	function isAdminLoggedIn(): bool
	{
		return isset($_SESSION['admin_id']) && !empty($_SESSION['admin_id']);
	}

	/**
	 * Get current user ID
	 */
	function getCurrentUserId(): ?int
	{
		return $_SESSION['user_id'] ?? null;
	}

	/**
	 * Get current admin ID
	 */
	function getCurrentAdminId(): ?int
	{
		return $_SESSION['admin_id'] ?? null;
	}

	/**
	 * Login user
	 */
	function loginUser(int $userId, bool $remember = false): void
	{
		$_SESSION['user_id'] = $userId;
		$_SESSION['login_time'] = time();
		$_SESSION['ip_address'] = getClientIp();
		
		// Generate CSRF token
		generateCsrfToken();
		
		// Update last login
		$db = Database::getInstance();
		$db->update('users', ['last_login' => date('Y-m-d H:i:s')], 'id = ?', [$userId]);
		
		// Log session in database
		$sessionToken = session_id();
		$db->insert('sessions', [
			'user_id' => $userId,
			'session_token' => $sessionToken,
			'csrf_token' => $_SESSION['csrf_token'],
			'ip_address' => getClientIp(),
			'user_agent' => $_SERVER['HTTP_USER_AGENT'] ?? '',
			'expires_at' => date('Y-m-d H:i:s', time() + SESSION_LIFETIME)
		]);
		
		if ($remember) {
			setRememberCookie($userId);
		}
	}

	/**
	 * Login admin
	 */
	function loginAdmin(int $adminId): void
	{
		$_SESSION['admin_id'] = $adminId;
		$_SESSION['admin_login_time'] = time();
		$_SESSION['ip_address'] = getClientIp();
		
		generateCsrfToken();
		
		$db = Database::getInstance();
		$db->update('admins', ['last_login' => date('Y-m-d H:i:s')], 'id = ?', [$adminId]);
		
		// Log admin action
		logAdminAction($adminId, 'login', 'admin', $adminId, 'Admin logged in');
	}

	/**
	 * Logout user
	 */
	function logoutUser(): void
	{
		if (isset($_SESSION['user_id'])) {
			$db = Database::getInstance();
			$db->delete('sessions', 'session_token = ?', [session_id()]);
		}
		
		$_SESSION = [];
		
		if (ini_get("session.use_cookies")) {
			$params = session_get_cookie_params();
			setcookie(session_name(), '', time() - 42000,
				$params["path"], $params["domain"],
				$params["secure"], $params["httponly"]
			);
		}
		
		// Clear remember cookie
		setcookie('remember_token', '', time() - 3600, '/', '.' . DOMAIN, true, true);
		
		session_destroy();
	}

	/**
	 * Logout admin
	 */
	function logoutAdmin(): void
	{
		if (isset($_SESSION['admin_id'])) {
			logAdminAction($_SESSION['admin_id'], 'logout', 'admin', $_SESSION['admin_id'], 'Admin logged out');
		}
		
		$_SESSION = [];
		session_destroy();
	}

	/**
	 * Set remember me cookie
	 */
	function setRememberCookie(int $userId): void
	{
		$token = generateToken();
		$expires = time() + (REMEMBER_ME_DAYS * 86400);
		
		setcookie(
			'remember_token',
			$token,
			$expires,
			'/',
			'.' . DOMAIN,
			true,
			true
		);
		
		// Store token hash in database
		$db = Database::getInstance();
		$db->update('users', ['api_token' => $token], 'id = ?', [$userId]);
	}

	/**
	 * Check remember me cookie
	 */
	function checkRememberCookie(): bool
	{
		if (!isset($_COOKIE['remember_token'])) {
			return false;
		}
		
		$token = $_COOKIE['remember_token'];
		$db = Database::getInstance();
		
		$user = $db->fetchOne('SELECT id FROM users WHERE api_token = ?', [$token]);
		
		if ($user) {
			$_SESSION['user_id'] = $user['id'];
			$_SESSION['login_time'] = time();
			return true;
		}
		
		return false;
	}

	/**
	 * Require user login
	 */
	function requireLogin(): void
	{
		if (!isLoggedIn()) {
			if (!checkRememberCookie()) {
				header('Location: /login.php');
				exit;
			}
		}
	}

	/**
	 * Require admin login
	 */
	function requireAdminLogin(): void
	{
		if (!isAdminLoggedIn()) {
			header('Location: /admin/login.php');
			exit;
		}
	}

	/**
	 * Log admin action
	 */
	function logAdminAction(int $adminId, string $action, string $targetType, ?int $targetId, ?string $details): void
	{
		$db = Database::getInstance();
		$db->insert('admin_logs', [
			'admin_id' => $adminId,
			'action' => $action,
			'target_type' => $targetType,
			'target_id' => $targetId,
			'details' => $details,
			'ip_address' => getClientIp()
		]);
	}
	PHPEOF
	}

	# Create IONOS API integration
	create_ionos_class() {
		print_status "info" "Creating IONOS API integration..."
		
		cat > "$WEB_ROOT/includes/classes/IONOS.php" << 'PHPEOF'
	<?php
	/**
	 * IONOS DNS API Integration
	 * 
	 * Handles DNS record management via IONOS API
	 * 
	 * API Documentation: https://developer.hosting.ionos.com/docs/dns
	 */

	class IONOS
	{
		private string $apiKey;
		private string $apiUrl;
		private string $zoneId;
		private array $lastError = [];
		
		/**
		 * Constructor
		 */
		public function __construct(?string $apiKey = null, ?string $zoneId = null)
		{
			$this->apiKey = $apiKey ?? $this->getApiKey();
			$this->apiUrl = IONOS_API_URL;
			$this->zoneId = $zoneId ?? $this->getZoneId();
		}
		
		/**
		 * Get API key from config
		 */
		private function getApiKey(): string
		{
			$configFile = INCLUDES_PATH . '/ionos_config.php';
			if (file_exists($configFile)) {
				$config = include $configFile;
				return $config['api_key'] ?? '';
			}
			return '';
		}
		
		/**
		 * Get Zone ID from config
		 */
		private function getZoneId(): string
		{
			$configFile = INCLUDES_PATH . '/ionos_config.php';
			if (file_exists($configFile)) {
				$config = include $configFile;
				return $config['zone_id'] ?? '';
			}
			return '';
		}
		
		/**
		 * Make API request
		 */
		private function request(string $method, string $endpoint, array $data = []): ?array
		{
			$url = $this->apiUrl . $endpoint;
			
			$headers = [
				'X-API-Key: ' . $this->apiKey,
				'Content-Type: application/json',
				'Accept: application/json'
			];
			
			$ch = curl_init();
			curl_setopt_array($ch, [
				CURLOPT_URL => $url,
				CURLOPT_RETURNTRANSFER => true,
				CURLOPT_CUSTOMREQUEST => $method,
				CURLOPT_HTTPHEADER => $headers,
				CURLOPT_TIMEOUT => 30,
				CURLOPT_SSL_VERIFYPEER => true
			]);
			
			if (!empty($data) && in_array($method, ['POST', 'PUT', 'PATCH'])) {
				curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
			}
			
			$response = curl_exec($ch);
			$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
			$error = curl_error($ch);
			curl_close($ch);
			
			if ($error) {
				$this->lastError = ['code' => 0, 'message' => $error];
				return null;
			}
			
			$decoded = json_decode($response, true);
			
			if ($httpCode >= 400) {
				$this->lastError = [
					'code' => $httpCode,
					'message' => $decoded['message'] ?? 'API request failed'
				];
				return null;
			}
			
			return $decoded;
		}
		
		/**
		 * Get last error
		 */
		public function getLastError(): array
		{
			return $this->lastError;
		}
		
		/**
		 * List all zones
		 */
		public function listZones(): ?array
		{
			return $this->request('GET', '/zones');
		}
		
		/**
		 * Get zone by domain
		 */
		public function getZoneByDomain(string $domain): ?array
		{
			$zones = $this->listZones();
			
			if (!$zones) {
				return null;
			}
			
			foreach ($zones as $zone) {
				if ($zone['name'] === $domain) {
					return $zone;
				}
			}
			
			return null;
		}
		
		/**
		 * Get all records for a zone
		 */
		public function getRecords(): ?array
		{
			if (empty($this->zoneId)) {
				$this->lastError = ['code' => 0, 'message' => 'Zone ID not configured'];
				return null;
			}
			
			return $this->request('GET', "/zones/{$this->zoneId}/records");
		}
		
		/**
		 * Get a specific record
		 */
		public function getRecord(string $recordId): ?array
		{
			return $this->request('GET', "/zones/{$this->zoneId}/records/{$recordId}");
		}
		
		/**
		 * Create a DNS record
		 */
		public function createRecord(string $name, string $type, string $content, int $ttl = 3600, int $prio = 0): ?array
		{
			if (empty($this->zoneId)) {
				$this->lastError = ['code' => 0, 'message' => 'Zone ID not configured'];
				return null;
			}
			
			$data = [
				'name' => $name,
				'type' => $type,
				'content' => $content,
				'ttl' => $ttl,
				'prio' => $prio,
				'disabled' => false
			];
			
			$result = $this->request('POST', "/zones/{$this->zoneId}/records", $data);
			
			$this->logDnsAction('create', $name, $type, $content);
			
			return $result;
		}
		
		/**
		 * Update a DNS record
		 */
		public function updateRecord(string $recordId, string $name, string $type, string $content, int $ttl = 3600, int $prio = 0): bool
		{
			$data = [
				'name' => $name,
				'type' => $type,
				'content' => $content,
				'ttl' => $ttl,
				'prio' => $prio,
				'disabled' => false
			];
			
			$result = $this->request('PUT', "/zones/{$this->zoneId}/records/{$recordId}", $data);
			
			$this->logDnsAction('update', $name, $type, $content);
			
			return $result !== null;
		}
		
		/**
		 * Delete a DNS record
		 */
		public function deleteRecord(string $recordId): bool
		{
			$result = $this->request('DELETE', "/zones/{$this->zoneId}/records/{$recordId}");
			
			$this->logDnsAction('delete', $recordId, '', '');
			
			return $result !== null;
		}
		
		/**
		 * Find record by name and type
		 */
		public function findRecord(string $name, string $type): ?array
		{
			$records = $this->getRecords();
			
			if (!$records) {
				return null;
			}
			
			foreach ($records as $record) {
				if ($record['name'] === $name && $record['type'] === $type) {
					return $record;
				}
			}
			
			return null;
		}
		
		/**
		 * Create or update A record for subdomain
		 */
		public function setARecord(string $subdomain, string $ipv4, int $ttl = 300): bool
		{
			$fullDomain = $subdomain . '.' . DOMAIN;
			
			$existing = $this->findRecord($fullDomain, 'A');
			
			if ($existing) {
				return $this->updateRecord(
					$existing['id'],
					$fullDomain,
					'A',
					$ipv4,
					$ttl
				);
			}
			
			return $this->createRecord($fullDomain, 'A', $ipv4, $ttl) !== null;
		}
		
		/**
		 * Create or update AAAA record for subdomain
		 */
		public function setAAAARecord(string $subdomain, string $ipv6, int $ttl = 300): bool
		{
			$fullDomain = $subdomain . '.' . DOMAIN;
			
			$existing = $this->findRecord($fullDomain, 'AAAA');
			
			if ($existing) {
				return $this->updateRecord(
					$existing['id'],
					$fullDomain,
					'AAAA',
					$ipv6,
					$ttl
				);
			}
			
			return $this->createRecord($fullDomain, 'AAAA', $ipv6, $ttl) !== null;
		}
		
		/**
		 * Delete all records for a subdomain
		 */
		public function deleteSubdomainRecords(string $subdomain): bool
		{
			$fullDomain = $subdomain . '.' . DOMAIN;
			$success = true;
			
			$records = $this->getRecords();
			
			if (!$records) {
				return false;
			}
			
			foreach ($records as $record) {
				if ($record['name'] === $fullDomain) {
					if (!$this->deleteRecord($record['id'])) {
						$success = false;
					}
				}
			}
			
			return $success;
		}
		
		/**
		 * Log DNS action
		 */
		private function logDnsAction(string $action, string $name, string $type, string $content): void
		{
			$logFile = LOG_PATH . '/dns.log';
			$timestamp = date('Y-m-d H:i:s');
			$message = "[$timestamp] $action: $name ($type) -> $content\n";
			file_put_contents($logFile, $message, FILE_APPEND);
		}
		
		/**
		 * Test API connection
		 */
		public function testConnection(): array
		{
			$zones = $this->listZones();
			
			if ($zones === null) {
				return [
					'success' => false,
					'error' => $this->lastError['message'] ?? 'Unknown error'
				];
			}
			
			return [
				'success' => true,
				'zones' => count($zones)
			];
		}
	}
	PHPEOF
	}

	# Create user registration handler
	create_registration_handler() {
		print_status "info" "Creating registration handler..."
		
		cat > "$WEB_ROOT/public/register.php" << 'PHPEOF'
	<?php
	/**
	 * User Registration Handler
	 */

	define('APP_ROOT', dirname(__DIR__));
	require_once APP_ROOT . '/includes/config.php';
	require_once APP_ROOT . '/includes/functions/security.php';
	require_once APP_ROOT . '/includes/functions/session.php';
	require_once APP_ROOT . '/includes/classes/Database.php';

	startSecureSession();
	setSecurityHeaders();

	// Redirect if already logged in
	if (isLoggedIn()) {
		header('Location: /dashboard.php');
		exit;
	}

	$errors = [];
	$success = false;
	$email = '';

	if ($_SERVER['REQUEST_METHOD'] === 'POST') {
		// Validate CSRF token
		if (!validateCsrfToken($_POST['csrf_token'] ?? '')) {
			$errors[] = 'Invalid security token. Please try again.';
		} else {
			// Check rate limit
			$rateLimit = checkRateLimit('register');
			if (!$rateLimit['allowed']) {
				$errors[] = 'Too many registration attempts. Please try again later.';
			} else {
				$email = sanitizeInput($_POST['email'] ?? '');
				$password = $_POST['password'] ?? '';
				$passwordConfirm = $_POST['password_confirm'] ?? '';
				
				// Validate email
				if (empty($email)) {
					$errors[] = 'Email address is required';
				} elseif (!validateEmail($email)) {
					$errors[] = 'Please enter a valid email address';
				} else {
					$db = Database::getInstance();
					if ($db->exists('users', 'email = ?', [$email])) {
						$errors[] = 'An account with this email already exists';
					}
				}
				
				// Validate password
				$passwordErrors = validatePassword($password);
				$errors = array_merge($errors, $passwordErrors);
				
				// Confirm password
				if ($password !== $passwordConfirm) {
					$errors[] = 'Passwords do not match';
				}
				
				// If no errors, create account
				if (empty($errors)) {
					$db = Database::getInstance();
					
					$passwordHash = hashPassword($password);
					$verificationToken = generateToken();
					$apiToken = generateApiToken();
					
					try {
						$userId = $db->insert('users', [
							'email' => $email,
							'password_hash' => $passwordHash,
							'verification_token' => $verificationToken,
							'api_token' => $apiToken,
							'email_verified' => 0
						]);
						
						// Send verification email
						sendVerificationEmail($email, $verificationToken);
						
						$success = true;
						$email = '';
						
						clearRateLimit('register');
						
					} catch (Exception $e) {
						$errors[] = 'Registration failed. Please try again.';
						recordRateLimitAttempt('register');
					}
				} else {
					recordRateLimitAttempt('register');
				}
			}
		}
	}

	/**
	 * Send verification email
	 */
	function sendVerificationEmail(string $email, string $token): bool
	{
		$verifyUrl = BASE_URL . '/verify.php?token=' . $token;
		
		$subject = 'Verify Your DDNS Account';
		
		$message = <<<HTML
	<!DOCTYPE html>
	<html>
	<head>
		<style>
			body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
			.container { max-width: 600px; margin: 0 auto; padding: 20px; }
			.button { display: inline-block; padding: 12px 24px; background: #6366f1; color: white; text-decoration: none; border-radius: 6px; }
			.footer { margin-top: 30px; font-size: 12px; color: #666; }
		</style>
	</head>
	<body>
		<div class="container">
			<h2>Welcome to DDNS Service!</h2>
			<p>Thank you for registering. Please verify your email address by clicking the button below:</p>
			<p><a href="{$verifyUrl}" class="button">Verify Email</a></p>
			<p>Or copy this link to your browser:</p>
			<p>{$verifyUrl}</p>
			<p>This link will expire in 24 hours.</p>
			<div class="footer">
				<p>If you didn't create this account, you can safely ignore this email.</p>
			</div>
		</div>
	</body>
	</html>
	HTML;
		
		$headers = [
			'MIME-Version: 1.0',
			'Content-type: text/html; charset=utf-8',
			'From: ' . EMAIL_FROM_NAME . ' <' . EMAIL_FROM . '>',
			'Reply-To: ' . EMAIL_FROM
		];
		
		return mail($email, $subject, $message, implode("\r\n", $headers));
	}

	// Generate new CSRF token
	$csrfToken = generateCsrfToken();

	// Include template
	include APP_ROOT . '/templates/header.php';
	?>
	<div class="auth-container">
		<div class="auth-card">
			<div class="auth-header">
				<h1>Create Account</h1>
				<p>Get your free subdomain</p>
			</div>
			
			<?php if ($success): ?>
			<div class="alert alert-success">
				<h3>Registration Successful!</h3>
				<p>Please check your email for a verification link.</p>
			</div>
			<?php else: ?>
			
			<?php if (!empty($errors)): ?>
			<div class="alert alert-error">
				<ul>
					<?php foreach ($errors as $error): ?>
					<li><?= h($error) ?></li>
					<?php endforeach; ?>
				</ul>
			</div>
			<?php endif; ?>
			
			<form method="POST" action="" class="auth-form">
				<?= csrfField() ?>
				
				<div class="form-group">
					<label for="email">Email Address</label>
					<input type="email" id="email" name="email" value="<?= h($email) ?>" 
						   placeholder="you@example.com" required autofocus
						   class="form-input">
				</div>
				
				<div class="form-group">
					<label for="password">Password</label>
					<input type="password" id="password" name="password" 
						   placeholder="Min 8 chars, upper, lower, number"
						   required class="form-input">
					<small class="form-hint">Minimum 8 characters with uppercase, lowercase, and number</small>
				</_box>
				
				<div class="form-group">
					<label for="password_confirm">Confirm Password</label>
					<input type="password" id="password_confirm" name="password_confirm" 
						   placeholder="Confirm your password"
						   required class="form-input">
				</div>
				
				<button type="submit" class="btn btn-primary btn-block">Create Account</button>
			</form>
			
			<div class="auth-footer">
				<p>Already have an account? <a href="/login.php">Sign in</a></p>
			</div>
			<?php endif; ?>
		</div>
	</div>
	<?php include APP_ROOT . '/templates/footer.php'; ?>
	PHPEOF
	}

	# Create remaining PHP files (abbreviated for space)
	create_remaining_php_files() {
		print_status "info" "Creating remaining PHP files..."
		
		# Login handler
		cat > "$WEB_ROOT/public/login.php" << 'PHPEOF'
	<?php
	/**
	 * User Login Handler
	 */

	define('APP_ROOT', dirname(__DIR__));
	require_once APP_ROOT . '/includes/config.php';
	require_once APP_ROOT . '/includes/functions/security.php';
	require_once APP_ROOT . '/includes/functions/session.php';
	require_once APP_ROOT . '/includes/classes/Database.php';

	startSecureSession();
	setSecurityHeaders();

	if (isLoggedIn()) {
		header('Location: /dashboard.php');
		exit;
	}

	$errors = [];
	$email = '';

	if ($_SERVER['REQUEST_METHOD'] === 'POST') {
		if (!validateCsrfToken($_POST['csrf_token'] ?? '')) {
			$errors[] = 'Invalid security token. Please try again.';
		} else {
			$rateLimit = checkRateLimit('login');
			
			if (!$rateLimit['allowed']) {
				$errors[] = 'Too many login attempts. Please try again in 15 minutes.';
			} else {
				$email = sanitizeInput($_POST['email'] ?? '');
				$password = $_POST['password'] ?? '';
				$remember = isset($_POST['remember']);
				
				if (empty($email) || empty($password)) {
					$errors[] = 'Please enter both email and password';
					recordRateLimitAttempt('login');
				} else {
					$db = Database::getInstance();
					$user = $db->fetchOne('SELECT * FROM users WHERE email = ?', [$email]);
					
					if (!$user || !verifyPassword($password, $user['password_hash'])) {
						$errors[] = 'Invalid email or password';
						recordRateLimitAttempt('login');
					} elseif (!$user['email_verified']) {
						$errors[] = 'Please verify your email address before logging in';
					} else {
						loginUser($user['id'], $remember);
						clearRateLimit('login');
						header('Location: /dashboard.php');
						exit;
					}
				}
			}
		}
	}

	$csrfToken = generateCsrfToken();
	include APP_ROOT . '/templates/header.php';
	?>
	<div class="auth-container">
		<div class="auth-card">
			<div class="auth-header">
				<h1>Welcome Back</h1>
				<p>Sign in to your account</p>
			</div>
			
			<?php if (!empty($errors)): ?>
			<div class="alert alert-error">
				<ul>
					<?php foreach ($errors as $error): ?>
					<li><?= h($error) ?></li>
					<?php endforeach; ?>
				</ul>
			</div>
			<?php endif; ?>
			
			<form method="POST" action="" class="auth-form">
				<?= csrfField() ?>
				
				<div class="form-group">
					<label for="email">Email Address</label>
					<input type="email" id="email" name="email" value="<?= h($email) ?>" 
						   placeholder="you@example.com" required autofocus
						   class="form-input">
				</div>
				
				<div class="form-group">
					<label for="password">Password</label>
					<input type="password" id="password" name="password" 
						   placeholder="Enter your password"
						   required class="form-input">
				</div>
				
				<div class="form-group form-check">
					<input type="checkbox" id="remember" name="remember" 
						   class="form-check-input">
					<label for="remember" class="form-check-label">Remember me</label>
				</div>
				
				<button type="submit" class="btn btn-primary btn-block">Sign In</button>
			</form>
			
			<div class="auth-footer">
				<p>Don't have an account? <a href="/register.php">Create one</a></p>
			</div>
		</div>
	</div>
	<?php include APP_ROOT . '/templates/footer.php'; ?>
	PHPEOF
	}
	PHPEOF
	}
	PHPEOF

		# Dashboard
		cat > "$WEB_ROOT/public/dashboard.php" << 'PHPEOF'
	<?php
	/**
	 * User Dashboard
	 */

	define('APP_ROOT', dirname(__DIR__));
	require_once APP_ROOT . '/includes/config.php';
	require_once APP_ROOT . '/includes/functions/security.php';
	require_once APP_ROOT . '/includes/functions/session.php';
	require_once APP_ROOT . '/includes/classes/Database.php';
	require_once APP_ROOT . '/includes/classes/IONOS.php';

	startSecureSession();
	setSecurityHeaders();
	requireLogin();

	$db = Database::getInstance();
	$userId = getCurrentUserId();

	// Get user data
	$user = $db->fetchOne('SELECT * FROM users WHERE id = ?', [$userId]);
	$subdomain = $db->fetchOne('SELECT * FROM subdomains WHERE user_id = ?', [$userId]);
	$updateLogs = [];

	if ($subdomain) {
		$updateLogs = $db->fetchAll(
			'SELECT * FROM update_logs WHERE subdomain_id = ? ORDER BY updated_at DESC LIMIT 10',
			[$subdomain['id']]
		);
	}

	$errors = [];
	$success = false;

	// Handle subdomain creation
	if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['create_subdomain'])) {
		if (!validateCsrfToken($_POST['csrf_token'] ?? '')) {
			$errors[] = 'Invalid security token.';
		} else {
			$subdomainName = strtolower(sanitizeInput($_POST['subdomain_name'] ?? ''));
			$validationErrors = validateSubdomain($subdomainName);
			$errors = array_merge($errors, $validationErrors);
			
			if (empty($errors)) {
				if ($db->exists('subdomains', 'subdomain_name = ?', [$subdomainName])) {
					$errors[] = 'This subdomain is already taken.';
				} else {
					try {
						$db->insert('subdomains', [
							'user_id' => $userId,
							'subdomain_name' => $subdomainName,
							'current_ipv4' => null,
							'current_ipv6' => null
						]);
						
						header('Location: /dashboard.php?created=1');
						exit;
					} catch (Exception $e) {
						$errors[] = 'Failed to create subdomain. Please try again.';
					}
				}
			}
		}
	}

	// Handle IP update
	if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['update_ip'])) {
		if (!validateCsrfToken($_POST['csrf_token'] ?? '')) {
			$errors[] = 'Invalid security token.';
		} elseif ($subdomain) {
			$ipv4 = sanitizeInput($_POST['ipv4'] ?? '');
			$ipv6 = sanitizeInput($_POST['ipv6'] ?? '');
			
			$oldIpv4 = $subdomain['current_ipv4'];
			$oldIpv6 = $subdomain['current_ipv6'];
			
			if (!empty($ipv4) && !validateIPv4($ipv4)) {
				$errors[] = 'Invalid IPv4 address';
			}
			
			if (!empty($ipv6) && !validateIPv6($ipv6)) {
				$errors[] = 'Invalid IPv6 address';
			}
			
			if (empty($errors)) {
				$db->beginTransaction();
				
				try {
					// Update database
					$db->update('subdomains', [
						'current_ipv4' => $ipv4 ?: null,
						'current_ipv6' => $ipv6 ?: null,
						'updated_at' => date('Y-m-d H:i:s')
					], 'id = ?', [$subdomain['id']]);
					
					// Log the update
					$db->insert('update_logs', [
						'subdomain_id' => $subdomain['id'],
						'old_ipv4' => $oldIpv4,
						'new_ipv4' => $ipv4 ?: null,
						'old_ipv6' => $oldIpv6,
						'new_ipv6' => $ipv6 ?: null,
						'ip_type' => ($ipv4 && $ipv6) ? 'both' : ($ipv4 ? 'ipv4' : 'ipv6')
					]);
					
					// Update DNS records
					$ionos = new IONOS();
					
					if ($ipv4) {
						$ionos->setARecord($subdomain['subdomain_name'], $ipv4);
					}
					
					if ($ipv6) {
						$ionos->setAAAARecord($subdomain['subdomain_name'], $ipv6);
					}
					
					$db->commit();
					
					header('Location: /dashboard.php?updated=1');
					exit;
					
				} catch (Exception $e) {
					$db->rollback();
					$errors[] = 'Failed to update IP. Please try again.';
				}
			}
		}
	}

	$csrfToken = generateCsrfToken();
	$clientIp = getClientIp();

	include APP_ROOT . '/templates/header.php';
	?>
	<div class="dashboard-container">
		<header class="dashboard-header">
			<div class="header-content">
				<h1>Dashboard</h1>
				<div class="user-menu">
					<span><?= h($user['email']) ?></span>
					<a href="/logout.php" class="btn btn-outline">Sign Out</a>
				</div>
			</div>
		</header>
		
		<?php if (isset($_GET['created'])): ?>
		<div class="alert alert-success">Subdomain created successfully!</div>
		<?php endif; ?>
		
		<?php if (isset($_GET['updated'])): ?>
		<div class="alert alert-success">IP address updated successfully!</div>
		<?php endif; ?>
		
		<?php if (!empty($errors)): ?>
		<div class="alert alert-error">
			<ul>
				<?php foreach ($errors as $error): ?>
				<li><?= h($error) ?></li>
				<?php endforeach; ?>
			</ul>
		</div>
		<?php endif; ?>
		
		<?php if (!$subdomain): ?>
		<!-- Create Subdomain -->
		<div class="card">
			<div class="card-header">
				<h2>Create Your Subdomain</h2>
			</div>
			<div class="card-body">
				<p>Choose a unique name for your subdomain under <strong><?= h(DOMAIN) ?></strong></p>
				
				<form method="POST" action="" class="form-inline">
					<?= csrfField() ?>
					<input type="hidden" name="create_subdomain" value="1">
					
					<div class="input-group">
						<input type="text" name="subdomain_name" 
							   placeholder="yourname" required
							   pattern="[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?"
							   minlength="3" maxlength="63"
							   class="form-input">
						<span class="input-suffix">.<?= h(DOMAIN) ?></span>
					</div>
					
					<button type="submit" class="btn btn-primary">Create Subdomain</button>
				</form>
			</div>
		</div>
		
		<?php else: ?>
		<!-- Subdomain Info -->
		<div class="grid">
			<div class="card">
				<div class="card-header">
					<h2>Your Subdomain</h2>
				</div>
				<div class="card-body">
					<div class="info-row">
						<span class="label">Domain:</span>
						<span class="value"><strong><?= h($subdomain['subdomain_name']) ?>.<?= h(DOMAIN) ?></strong></span>
					</div>
					<div class="info-row">
						<span class="label">IPv4:</span>
						<span class="value"><?= h($subdomain['current_ipv4'] ?: 'Not set') ?></span>
					</div>
					<div class="info-row">
						<span class="label">IPv6:</span>
						<span class="value"><?= h($subdomain['current_ipv6'] ?: 'Not set') ?></span>
					</div>
					<div class="info-row">
						<span class="label">Last Updated:</span>
						<span class="value"><?= h($subdomain['updated_at'] ?? 'Never') ?></span>
					</div>
				</div>
			</div>
			
			<div class="card">
				<div class="card-header">
					<h2>Update IP Address</h2>
				</div>
				<div class="card-body">
					<form method="POST" action="">
						<?= csrfField() ?>
						<input type="hidden" name="update_ip" value="1">
						
						<div class="form-group">
							<label for="ipv4">IPv4 Address</label>
							<input type="text" id="ipv4" name="ipv4" 
								   value="<?= h($subdomain['current_ipv4'] ?? $clientIp) ?>"
								   placeholder="e.g., 192.0.2.1"
								   class="form-input">
							<small class="form-hint">Your detected IP: <?= h($clientIp) ?></small>
						</div>
						
						<div class="form-group">
							<label for="ipv6">IPv6 Address</label>
							<input type="text" id="ipv6" name="ipv6" 
								   value="<?= h($subdomain['current_ipv6'] ?? '') ?>"
								   placeholder="e.g., 2001:db8::1"
								   class="form-input">
						</div>
						
						<button type="submit" class="btn btn-primary btn-block">Update IP</button>
					</form>
				</div>
			</div>
			
			<!-- API Token -->
			<div class="card">
				<div class="card-header">
					<h2>API Access</h2>
				</div>
				<div class="card-body">
					<p>Use this token for programmatic updates:</p>
					<div class="code-block">
						<code id="api-token"><?= h($user['api_token']) ?></code>
						<button onclick="copyToken()" class="btn btn-sm btn-outline">Copy</button>
					</div>
					
					<h4>Update via API:</h4>
					<pre class="code-block"><code>curl -X POST "https://<?= h(DOMAIN) ?>/api/update.php" \
	  -H "Authorization: Bearer YOUR_API_TOKEN" \
	  -d "ipv4=YOUR_IP"</code></pre>
				</div>
			</div>
		</div>
		
		<!-- Update History -->
		<div class="card">
			<div class="card-header">
				<h2>Update History</h2>
			</div>
			<div class="card-body">
				<?php if (empty($updateLogs)): ?>
				<p class="text-muted">No updates yet.</p>
				<?php else: ?>
				<table class="table">
					<thead>
						<tr>
							<th>Time</th>
							<th>Old IPv4</th>
							<th>New IPv4</th>
							<th>Old IPv6</th>
							<th>New IPv6</th>
						</tr>
					</thead>
					<tbody>
						<?php foreach ($updateLogs as $log): ?>
						<tr>
							<td><?= h($log['updated_at']) ?></td>
							<td><?= h($log['old_ipv4'] ?? '-') ?></td>
							<td><?= h($log['new_ipv4'] ?? '-') ?></td>
							<td><?= h($log['old_ipv6'] ?? '-') ?></td>
							<td><?= h($log['new_ipv6'] ?? '-') ?></td>
						</tr>
						<?php endforeach; ?>
					</tbody>
				</table>
				<?php endif; ?>
			</div>
		</div>
		<?php endif; ?>
	</div>

	<script>
	function copyToken() {
		const token = document.getElementById('api-token').textContent;
		navigator.clipboard.writeText(token).then(() => {
			alert('API token copied to clipboard!');
		});
	}
	</script>

	<?php include APP_ROOT . '/templates/footer.php'; ?>
	PHPEOF
	}

	# Create logout handler
	create_logout_handler() {
		cat > "$WEB_ROOT/public/logout.php" << 'PHPEOF'
	<?php
	define('APP_ROOT', dirname(__DIR__));
	require_once APP_ROOT . '/includes/config.php';
	require_once APP_ROOT . '/includes/functions/session.php';

	startSecureSession();
	logoutUser();

	header('Location: /login.php');
	exit;
	PHPEOF
	}

	# Create email verification handler
	create_verification_handler() {
		cat > "$WEB_ROOT/public/verify.php" << 'PHPEOF'
	<?php
	define('APP_ROOT', dirname(__DIR__));
	require_once APP_ROOT . '/includes/config.php';
	require_once APP_ROOT . '/includes/functions/security.php';
	require_once APP_ROOT . '/includes/functions/session.php';
	require_once APP_ROOT . '/includes/classes/Database.php';

	startSecureSession();

	$token = $_GET['token'] ?? '';
	$error = null;
	$success = false;

	if (empty($token)) {
		$error = 'Invalid verification link.';
	} else {
		$db = Database::getInstance();
		$user = $db->fetchOne(
			'SELECT * FROM users WHERE verification_token = ?',
			[$token]
		);
		
		if (!$user) {
			$error = 'Invalid or expired verification link.';
		} else {
			// Check if token expired (24 hours)
			$createdAt = strtotime($user['created_at']);
			if (time() - $createdAt > EMAIL_VERIFICATION_EXPIRY) {
				$error = 'Verification link has expired. Please register again.';
			} else {
				$db->update('users', [
					'email_verified' => 1,
					'verification_token' => null
				], 'id = ?', [$user['id']]);
				
				$success = true;
			}
		}
	}

	include APP_ROOT . '/templates/header.php';
	?>
	<div class="auth-container">
		<div class="auth-card">
			<?php if ($success): ?>
			<div class="alert alert-success">
				<h3>Email Verified!</h3>
				<p>Your email has been verified. You can now <a href="/login.php">sign in</a>.</p>
			</div>
			<?php else: ?>
			<div class="alert alert-error">
				<h3>Verification Failed</h3>
				<p><?= h($error) ?></p>
				<p><a href="/register.php">Try registering again</a></p>
			</div>
			<?php endif; ?>
		</div>
	</div>
	<?php include APP_ROOT . '/templates/footer.php'; ?>
	PHPEOF
	}

	# Create API endpoint
	create_api_endpoint() {
		cat > "$WEB_ROOT/api/update.php" << 'PHPEOF'
	<?php
	/**
	 * DDNS Update API Endpoint
	 * 
	 * Usage:
	 *   curl -X POST "https://rslvd.net/api/update.php" \
	 *     -H "Authorization: Bearer YOUR_API_TOKEN" \
	 *     -d "ipv4=192.0.2.1" \
	 *     -d "ipv6=2001:db8::1"
	 */

	header('Content-Type: application/json');

	define('APP_ROOT', dirname(__DIR__));
	require_once APP_ROOT . '/includes/config.php';
	require_once APP_ROOT . '/includes/functions/security.php';
	require_once APP_ROOT . '/includes/classes/Database.php';
	require_once APP_ROOT . '/includes/classes/IONOS.php';

	// Only allow POST requests
	if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
		http_response_code(405);
		echo json_encode(['error' => 'Method not allowed']);
		exit;
	}

	// Get API token from Authorization header
	$authHeader = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
	if (!preg_match('/Bearer\s+(.+)$/i', $authHeader, $matches)) {
		http_response_code(401);
		echo json_encode(['error' => 'Missing or invalid authorization header']);
		exit;
	}

	$apiToken = $matches[1];

	// Validate token
	$db = Database::getInstance();
	$user = $db->fetchOne('SELECT * FROM users WHERE api_token = ? AND email_verified = 1', [$apiToken]);

	if (!$user) {
		http_response_code(401);
		echo json_encode(['error' => 'Invalid API token']);
		exit;
	}

	// Get subdomain
	$subdomain = $db->fetchOne('SELECT * FROM subdomains WHERE user_id = ?', [$user['id']]);

	if (!$subdomain) {
		http_response_code(404);
		echo json_encode(['error' => 'No subdomain configured']);
		exit;
	}

	// Get IP addresses
	$ipv4 = sanitizeInput($_POST['ipv4'] ?? '');
	$ipv6 = sanitizeInput($_POST['ipv6'] ?? '');

	// Auto-detect if not provided
	if (empty($ipv4) && empty($ipv6)) {
		$ipv4 = getClientIp();
	}

	// Validate
	if (!empty($ipv4) && !validateIPv4($ipv4)) {
		http_response_code(400);
		echo json_encode(['error' => 'Invalid IPv4 address']);
		exit;
	}

	if (!empty($ipv6) && !validateIPv6($ipv6)) {
		http_response_code(400);
		echo json_encode(['error' => 'Invalid IPv6 address']);
		exit;
	}

	$oldIpv4 = $subdomain['current_ipv4'];
	$oldIpv6 = $subdomain['current_ipv6'];

	try {
		$db->beginTransaction();
		
		// Update database
		$db->update('subdomains', [
			'current_ipv4' => $ipv4 ?: null,
			'current_ipv6' => $ipv6 ?: null,
			'updated_at' => date('Y-m-d H:i:s')
		], 'id = ?', [$subdomain['id']]);
		
		// Log update
		$db->insert('update_logs', [
			'subdomain_id' => $subdomain['id'],
			'old_ipv4' => $oldIpv4,
			'new_ipv4' => $ipv4 ?: null,
			'old_ipv6' => $oldIpv6,
			'new_ipv6' => $ipv6 ?: null,
			'ip_type' => ($ipv4 && $ipv6) ? 'both' : ($ipv4 ? 'ipv4' : 'ipv6')
		]);
		
		// Update DNS
		$ionos = new IONOS();
		$dnsResults = [];
		
		if ($ipv4) {
			$result = $ionos->setARecord($subdomain['subdomain_name'], $ipv4);
			$dnsResults['ipv4'] = $result ? 'updated' : 'failed';
		}
		
		if ($ipv6) {
			$result = $ionos->setAAAARecord($subdomain['subdomain_name'], $ipv6);
			$dnsResults['ipv6'] = $result ? 'updated' : 'failed';
		}
		
		$db->commit();
		
		echo json_encode([
			'success' => true,
			'subdomain' => $subdomain['subdomain_name'] . '.' . DOMAIN,
			'ipv4' => $ipv4 ?: null,
			'ipv6' => $ipv6 ?: null,
			'dns' => $dnsResults,
			'updated_at' => date('c')
		]);
		
	} catch (Exception $e) {
		$db->rollback();
		http_response_code(500);
		echo json_encode(['error' => 'Update failed: ' . $e->getMessage()]);
	}
	PHPEOF
	}

	# Create admin login
	create_admin_login() {
		cat > "$WEB_ROOT/admin/login.php" << 'PHPEOF'
	<?php
	define('APP_ROOT', dirname(__DIR__));
	require_once APP_ROOT . '/includes/config.php';
	require_once APP_ROOT . '/includes/functions/security.php';
	require_once APP_ROOT . '/includes/functions/session.php';
	require_once APP_ROOT . '/includes/classes/Database.php';

	startSecureSession();

	if (isAdminLoggedIn()) {
		header('Location: /admin/');
		exit;
	}

	$errors = [];
	$email = '';

	if ($_SERVER['REQUEST_METHOD'] === 'POST') {
		if (!validateCsrfToken($_POST['csrf_token'] ?? '')) {
			$errors[] = 'Invalid security token.';
		} else {
			$rateLimit = checkRateLimit('admin_login');
			
			if (!$rateLimit['allowed']) {
				$errors[] = 'Too many login attempts.';
			} else {
				$email = sanitizeInput($_POST['email'] ?? '');
				$password = $_POST['password'] ?? '';
				
				$db = Database::getInstance();
				$admin = $db->fetchOne('SELECT * FROM admins WHERE email = ?', [$email]);
				
				if (!$admin || !verifyPassword($password, $admin['password_hash'])) {
					$errors[] = 'Invalid credentials.';
					recordRateLimitAttempt('admin_login');
				} else {
					loginAdmin($admin['id']);
					clearRateLimit('admin_login');
					header('Location: /admin/');
					exit;
				}
			}
		}
	}

	$csrfToken = generateCsrfToken();
	?>
	<!DOCTYPE html>
	<html lang="en">
	<head>
		<meta charset="UTF-8">
		<meta name="viewport" content="width=device-width, initial-scale=1.0">
		<title>Admin Login - DDNS</title>
		<link rel="stylesheet" href="/css/style.css">
	</head>
	<body class="dark-theme">
		<div class="auth-container">
			<div class="auth-card">
				<div class="auth-header">
					<h1>Admin Panel</h1>
					<p>Sign in to access admin features</p>
				</div>
				
				<?php if (!empty($errors)): ?>
				<div class="alert alert-error">
					<?php foreach ($errors as $error): ?>
					<p><?= h($error) ?></p>
					<?php endforeach; ?>
				</div>
				<?php endif; ?>
				
				<form method="POST" action="" class="auth-form">
					<input type="hidden" name="csrf_token" value="<?= h($csrfToken) ?>">
					
					<div class="form-group">
						<label for="email">Email</label>
						<input type="email" id="email" name="email" value="<?= h($email) ?>" 
							   required autofocus class="form-input">
					</div>
					
					<div class="form-group">
						<label for="password">Password</label>
						<input type="password" id="password" name="password" 
							   required class="form-input">
					</div>
					
					<button type="submit" class="btn btn-primary btn-block">Sign In</button>
				</form>
			</div>
		</div>
	</body>
	</html>
	PHPEOF
	}

	# Create admin dashboard
	create_admin_dashboard() {
		cat > "$WEB_ROOT/admin/index.php" << 'PHPEOF'
	<?php
	define('APP_ROOT', dirname(__DIR__));
	require_once APP_ROOT . '/includes/config.php';
	require_once APP_ROOT . '/includes/functions/security.php';
	require_once APP_ROOT . '/includes/functions/session.php';
	require_once APP_ROOT . '/includes/classes/Database.php';

	startSecureSession();
	setSecurityHeaders();
	requireAdminLogin();

	$db = Database::getInstance();
	$adminId = getCurrentAdminId();

	// Get statistics
	$totalUsers = $db->count('users');
	$verifiedUsers = $db->count('users', 'email_verified = 1');
	$totalSubdomains = $db->count('subdomains');
	$activeSubdomains = $db->count('subdomains', 'active = 1');

	// Get recent users
	$recentUsers = $db->fetchAll(
		'SELECT u.id, u.email, u.email_verified, u.created_at, s.subdomain_name, s.current_ipv4
		 FROM users u 
		 LEFT JOIN subdomains s ON u.id = s.user_id 
		 ORDER BY u.created_at DESC LIMIT 20'
	);

	// Handle actions
	if ($_SERVER['REQUEST_METHOD'] === 'POST') {
		if (!validateCsrfToken($_POST['csrf_token'] ?? '')) {
			$error = 'Invalid security token.';
		} else {
			$action = $_POST['action'] ?? '';
			
			switch ($action) {
				case 'delete_user':
					$userId = (int)($_POST['user_id'] ?? 0);
					if ($userId > 0) {
						// Get subdomain first
						$sub = $db->fetchOne('SELECT subdomain_name FROM subdomains WHERE user_id = ?', [$userId]);
						if ($sub) {
							// Delete DNS records
							$ionos = new IONOS();
							$ionos->deleteSubdomainRecords($sub['subdomain_name']);
						}
						
						$db->delete('users', 'id = ?', [$userId]);
						logAdminAction($adminId, 'delete_user', 'user', $userId, 'Deleted user');
						header('Location: ?deleted=user');
						exit;
					}
					break;
					
				case 'delete_subdomain':
					$subdomainId = (int)($_POST['subdomain_id'] ?? 0);
					if ($subdomainId > 0) {
						$sub = $db->fetchOne('SELECT * FROM subdomains WHERE id = ?', [$subdomainId]);
						if ($sub) {
							$ionos = new IONOS();
							$ionos->deleteSubdomainRecords($sub['subdomain_name']);
							$db->delete('subdomains', 'id = ?', [$subdomainId]);
							logAdminAction($adminId, 'delete_subdomain', 'subdomain', $subdomainId, 'Deleted subdomain: ' . $sub['subdomain_name']);
							header('Location: ?deleted=subdomain');
							exit;
						}
					}
					break;
					
				case 'export_csv':
					header('Content-Type: text/csv');
					header('Content-Disposition: attachment; filename="ddns_export_' . date('Y-m-d') . '.csv"');
					
					$output = fopen('php://output', 'w');
					fputcsv($output, ['ID', 'Email', 'Verified', 'Subdomain', 'IPv4', 'IPv6', 'Created', 'Updated']);
					
					foreach ($recentUsers as $user) {
						fputcsv($output, [
							$user['id'],
							$user['email'],
							$user['email_verified'] ? 'Yes' : 'No',
							$user['subdomain_name'] ?? '',
							$user['current_ipv4'] ?? '',
							'',
							$user['created_at']
						]);
					}
					
					fclose($output);
					exit;
			}
		}
	}

	$csrfToken = generateCsrfToken();
	?>
	<!DOCTYPE html>
	<html lang="en">
	<head>
		<meta charset="UTF-8">
		<meta name="viewport" content="width=device-width, initial-scale=1.0">
		<title>Admin Dashboard - DDNS</title>
		<link rel="stylesheet" href="/css/style.css">
	</head>
	<body class="dark-theme">
		<div class="admin-container">
			<header class="admin-header">
				<div class="header-content">
					<h1>DDNS Admin</h1>
					<div class="admin-nav">
						<a href="/" target="_blank">View Site</a>
						<a href="/admin/logout.php">Sign Out</a>
					</div>
				</div>
			</header>
			
			<?php if (isset($_GET['deleted'])): ?>
			<div class="alert alert-success">Item deleted successfully.</div>
			<?php endif; ?>
			
			<!-- Statistics Cards -->
			<div class="stats-grid">
				<div class="stat-card">
					<div class="stat-value"><?= $totalUsers ?></div>
					<div class="stat-label">Total Users</div>
				</div>
				<div class="stat-card">
					<div class="stat-value"><?= $verifiedUsers ?></div>
					<div class="stat-label">Verified Users</div>
				</div>
				<div class="stat-card">
					<div class="stat-value"><?= $totalSubdomains ?></div>
					<div class="stat-label">Subdomains</div>
				</div>
				<div class="stat-card">
					<div class="stat-value"><?= $activeSubdomains ?></div>
					<div class="stat-label">Active</div>
				</div>
			</div>
			
			<!-- Users Table -->
			<div class="card">
				<div class="card-header">
					<h2>Users & Subdomains</h2>
					<form method="POST" action="" style="display:inline">
						<input type="hidden" name="csrf_token" value="<?= h($csrfToken) ?>">
						<input type="hidden" name="action" value="export_csv">
						<button type="submit" class="btn btn-sm btn-outline">Export CSV</button>
					</form>
				</div>
				<div class="card-body">
					<table class="table">
						<thead>
							<tr>
								<th>ID</th>
								<th>Email</th>
								<th>Verified</th>
								<th>Subdomain</th>
								<th>IP</th>
								<th>Created</th>
								<th>Actions</th>
							</tr>
						</thead>
						<tbody>
							<?php foreach ($recentUsers as $user): ?>
							<tr>
								<td><?= h($user['id']) ?></td>
								<td><?= h($user['email']) ?></td>
								<td>
									<?php if ($user['email_verified']): ?>
									<span class="badge badge-success">Verified</span>
									<?php else: ?>
									<span class="badge badge-warning">Pending</span>
									<?php endif; ?>
								</td>
								<td>
									<?php if ($user['subdomain_name']): ?>
									<a href="http://<?= h($user['subdomain_name']) ?>.<?= h(DOMAIN) ?>" target="_blank">
										<?= h($user['subdomain_name']) ?>.<?= h(DOMAIN) ?>
									</a>
									<?php else: ?>
									<span class="text-muted">None</span>
									<?php endif; ?>
								</td>
								<td><?= h($user['current_ipv4'] ?? '-') ?></td>
								<td><?= h($user['created_at']) ?></td>
								<td>
									<form method="POST" action="" style="display:inline" 
										  onsubmit="return confirm('Are you sure?')">
										<input type="hidden" name="csrf_token" value="<?= h($csrfToken) ?>">
										<input type="hidden" name="user_id" value="<?= h($user['id']) ?>">
										<input type="hidden" name="action" value="delete_user">
										<button type="submit" class="btn btn-sm btn-danger">Delete</button>
									</form>
								</td>
							</tr>
							<?php endforeach; ?>
						</tbody>
					</table>
				</div>
			</div>
		</div>
	</body>
	</html>
	PHPEOF
	}

	# Create admin logout
	create_admin_logout() {
		cat > "$WEB_ROOT/admin/logout.php" << 'PHPEOF'
	<?php
	define('APP_ROOT', dirname(__DIR__));
	require_once APP_ROOT . '/includes/config.php';
	require_once APP_ROOT . '/includes/functions/session.php';

	startSecureSession();
	logoutAdmin();

	header('Location: /admin/login.php');
	exit;
	PHPEOF
	}