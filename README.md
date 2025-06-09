# Supabase Backup with Restic

This repository contains a comprehensive backup solution for Supabase self-hosted instances, using Restic for encrypted backups. It's designed to work with the [supabase-automated-self-host](https://github.com/singh-inder/supabase-automated-self-host/) repository.

## Features

- PostgreSQL database dumps
- Configuration backup (.env, Caddy, Authelia, Docker Compose)
- MinIO bucket backup via rclone
- Encrypted backup to multiple storage providers:
  - DigitalOcean Spaces
  - Amazon S3
  - Hetzner Object Storage (S3-compatible with limitations)
- Automatic retention policy
- Clean logging

## Prerequisites

### Required Software
- Docker and Docker Compose (required for Supabase self-hosted setup)
- Restic (latest version)
- Rclone (latest version)
- Git

### Software Installation

#### Restic Installation (Ubuntu 22.04)
```bash
# Add Restic repository
curl -fsSL https://apt.restic.net/restic.gpg | sudo gpg --dearmor -o /usr/share/keyrings/restic-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/restic-archive-keyring.gpg] https://apt.restic.net/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/restic.list

# Update package list and install Restic
sudo apt update
sudo apt install restic
```

#### Rclone Installation (Ubuntu 22.04)
```bash
# Check if Rclone is already installed
if command -v rclone &> /dev/null; then
    echo "Rclone is already installed. Current version:"
    rclone version
    echo "To update to the latest version, run:"
    echo "curl https://rclone.org/install.sh | sudo bash"
else
    # Download and install Rclone
    curl https://rclone.org/install.sh | sudo bash
fi

# Create Rclone config directory if it doesn't exist
mkdir -p ~/.config/rclone
```

### Required Accounts
- One of the following storage providers:
  - DigitalOcean Spaces account
  - Amazon S3 account
  - Hetzner Object Storage account
- MinIO instance (part of Supabase self-hosted setup)

### Required Information
- Storage provider credentials
- MinIO access and secret keys
- Supabase database credentials
- Strong password for Restic encryption

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/supabase-backup.git
   cd supabase-backup
   ```

2. Create the backup directory and set permissions:
   ```bash
   # Create directory with proper ownership
   sudo mkdir -p /opt/supabase-backups
   sudo cp supabase_backup_restic.sh /opt/supabase-backups/
   sudo chown -R $USER:$USER /opt/supabase-backups
   sudo chmod +x /opt/supabase-backups/supabase_backup_restic.sh
   ```

3. Configure restic:
   ```bash
   cp restic.env.example /opt/supabase-backups/restic.env
   chmod 600 /opt/supabase-backups/restic.env  # Restrict permissions to owner only
   # Edit restic.env with your storage provider credentials
   ```

4. Configure rclone:
   ```bash
   mkdir -p ~/.config/rclone
   cp rclone.conf.example ~/.config/rclone/rclone.conf
   chmod 600 ~/.config/rclone/rclone.conf  # Restrict permissions to owner only
   # Edit rclone.conf with your MinIO credentials
   ```

## Storage Provider Setup

### Storage Provider Comparison

| Provider | Encryption Type | Additional Requirements |
|:---------|:---------------|:----------------------|
| DigitalOcean Spaces | S3 Default | None |
| Amazon S3 | S3 Default | None |
| Hetzner Object Storage | SSE-C Only | Requires SSE-C key management |

### 1. DigitalOcean Spaces
1. Create a Space in your DigitalOcean account
2. Generate API keys (Access Key and Secret Key)
3. In `restic.env`:
   ```bash
   RESTIC_REPOSITORY=s3:https://fra1.digitaloceanspaces.com/your-space-name
   AWS_ACCESS_KEY_ID=your_access_key
   AWS_SECRET_ACCESS_KEY=your_secret_key
   ```

### 2. Amazon S3
1. Create an S3 bucket in your AWS account
2. Create an IAM user with S3 access
3. Generate access keys for the IAM user
4. In `restic.env`:
   ```bash
   RESTIC_REPOSITORY=s3:s3.amazonaws.com/your-bucket-name
   AWS_ACCESS_KEY_ID=your_access_key
   AWS_SECRET_ACCESS_KEY=your_secret_key
   ```

### 3. Hetzner Object Storage
1. Create a bucket in Hetzner Object Storage
2. Generate access keys in the Hetzner Cloud Console
3. Important limitations to be aware of:
   - Only SSE-C encryption is supported (different from other providers)
   - No support for Request-Payment, Notifications, Accelerate, Website, Analytics
   - No support for Intelligent Tiering, Inventory, Logging, Metrics
   - No support for Ownership Controls, Replication, Tagging
   - No support for custom domains for buckets
4. Generate SSE-C key (Hetzner-specific requirement):
   ```bash
   # Generate a 32-byte (256-bit) key and encode it in base64
   openssl rand -base64 32 > /opt/supabase-backups/sse-c-key.txt
   # Set proper permissions
   chmod 600 /opt/supabase-backups/sse-c-key.txt
   ```
   Store this key securely - you'll need it for both backup and restore operations.
5. In `restic.env`:
   ```bash
   RESTIC_REPOSITORY=s3:https://eu-central-1.hetzner.com/your-bucket-name
   AWS_ACCESS_KEY_ID=your-hetzner-access-key
   AWS_SECRET_ACCESS_KEY=your-hetzner-secret-key
   RESTIC_S3_SSE_C_KEY=$(cat /opt/supabase-backups/sse-c-key.txt)  # Hetzner-specific requirement
   ```

### Hetzner SSE-C Key Management (Hetzner-specific)

The SSE-C (Server-Side Encryption with Customer-Provided Keys) key is required only for Hetzner Object Storage. Other providers (DigitalOcean Spaces and Amazon S3) use their own encryption methods and don't require this key.

1. Key Generation:
   - Always use a cryptographically secure random generator (like OpenSSL)
   - The key must be 32 bytes (256 bits) for AES-256 encryption
   - Base64 encoding is required for the key format

2. Key Storage:
   - Store the key in a secure location with restricted permissions (600)
   - Consider using a key management service for production environments
   - Never commit the key to version control
   - Keep a secure backup of the key - if lost, you cannot decrypt your backups

3. Key Rotation:
   - While Hetzner doesn't require key rotation, it's a good security practice
   - To rotate keys:
     ```bash
     # Generate new key
     openssl rand -base64 32 > /opt/supabase-backups/sse-c-key-new.txt
     chmod 600 /opt/supabase-backups/sse-c-key-new.txt
     
     # Create new backup with new key
     export RESTIC_S3_SSE_C_KEY=$(cat /opt/supabase-backups/sse-c-key-new.txt)
     restic backup /path/to/data
     
     # Verify backup is accessible with new key
     restic snapshots
     
     # If successful, replace old key
     mv /opt/supabase-backups/sse-c-key-new.txt /opt/supabase-backups/sse-c-key.txt
     ```

4. Disaster Recovery:
   - Document the key generation process
   - Store the key in a secure, accessible location
   - Consider using a password manager or secure vault
   - Test restore procedures regularly with the key

5. Security Best Practices:
   - Use different SSE-C keys for different environments (dev/staging/prod)
   - Monitor access to the key file
   - Implement key rotation policies
   - Document key management procedures

## MinIO Configuration

1. Get your MinIO credentials from your Supabase `.env` file:
   ```
   MINIO_ROOT_USER=your_access_key
   MINIO_ROOT_PASSWORD=your_secret_key
   ```

2. Configure rclone:
   ```bash
   rclone config
   ```
   Use these settings:
   - Type: s3
   - Provider: Minio
   - Access Key: Your MinIO access key
   - Secret Key: Your MinIO secret key
   - Endpoint: Your MinIO endpoint (usually http://localhost:9000)
   - Region: us-east-1

## Cronjob Setup

Add to crontab:
```bash
# Edit crontab for current user
crontab -e
```

Add this line:
```
0 3 * * * /opt/supabase-backups/supabase_backup_restic.sh >> /opt/supabase-backups/cron.log 2>&1
```

## Restore Process

1. List available backups:
   ```bash
   source /opt/supabase-backups/restic.env
   restic snapshots
   ```

2. Restore the latest backup:
   ```bash
   restic restore latest --target /tmp/restore
   ```

3. Restore components:
   - PostgreSQL: Use the .backup file to restore the database
   - Configuration: Copy files from /tmp/restore/config to your Supabase directory
   - MinIO buckets: Use rclone to copy data back to MinIO

## Backup Retention

The script implements the following retention policy:
- Daily backups: 7 days
- Weekly backups: 4 weeks
- Monthly backups: 6 months

## Logging

- Main backup log: `/opt/supabase-backups/backup.log`
- Cron job log: `/opt/supabase-backups/cron.log`

## Security Notes

- Keep your `restic.env` file secure and restrict access (chmod 600)
- Use strong passwords for Restic encryption
- Regularly rotate your storage provider access keys
- Monitor backup logs for any issues
- Store your Restic password securely - it's required for restore operations
- For Hetzner Object Storage: Keep your SSE-C key secure as it's required for both backup and restore
- Ensure all configuration files have restricted permissions (chmod 600)
- Run the backup script as a regular user with sudo privileges, not as root

## Troubleshooting

1. Check backup logs:
   ```bash
   tail -f /opt/supabase-backups/backup.log
   ```

2. Verify rclone configuration:
   ```bash
   rclone lsd minio:
   ```

3. Test restic connection:
   ```bash
   source /opt/supabase-backups/restic.env
   restic snapshots
   ```

4. Common issues:
   - Permission denied: Check file permissions and ownership
   - Connection errors: Verify network connectivity and credentials
   - Storage full: Check available space in your storage provider
   - MinIO sync issues: Verify MinIO is running and accessible
   - Hetzner SSE-C errors: Ensure SSE-C key is properly set and consistent

## License

GNU Public License
