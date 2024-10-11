# Provider configuration
provider "aws" {
  region = "us-west-2"
}

# VPC and Networking
resource "aws_vpc" "streamscribe_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "streamscribe-vpc"
  }
}

resource "aws_subnet" "streamscribe_subnet" {
  vpc_id                  = aws_vpc.streamscribe_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-west-2a"  # Change this according to your region

  tags = {
    Name = "streamscribe-subnet"
  }
}

resource "aws_internet_gateway" "streamscribe_igw" {
  vpc_id = aws_vpc.streamscribe_vpc.id

  tags = {
    Name = "streamscribe-igw"
  }
}

resource "aws_route_table" "streamscribe_rt" {
  vpc_id = aws_vpc.streamscribe_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.streamscribe_igw.id
  }

  tags = {
    Name = "streamscribe-rt"
  }
}

resource "aws_route_table_association" "streamscribe_rta" {
  subnet_id      = aws_subnet.streamscribe_subnet.id
  route_table_id = aws_route_table.streamscribe_rt.id
}

# Security Group
resource "aws_security_group" "streamscribe_sg" {
  name        = "streamscribe-sg"
  description = "Security group for StreamScribe EC2 instance"
  vpc_id      = aws_vpc.streamscribe_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Consider restricting to your IP for production
  }

  ingress {
    from_port   = 8501
    to_port     = 8501
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Streamlit port
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "streamscribe-sg"
  }
}

# S3 Bucket
resource "aws_s3_bucket" "streamscribe_bucket" {
  bucket        = "streamscribe-data-bucket"  # Change this to your preferred bucket name
  force_destroy = false

  # lifecycle {
  #   prevent_destroy = true
  # }

  tags = {
    Name = "streamscribe-bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "streamscribe_bucket_access" {
  bucket = aws_s3_bucket.streamscribe_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM Role for EC2
resource "aws_iam_role" "streamscribe_role" {
  name = "streamscribe_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "streamscribe-role"
  }
}

# IAM Policy for S3 access
resource "aws_iam_role_policy" "streamscribe_s3_policy" {
  name = "streamscribe_s3_policy"
  role = aws_iam_role.streamscribe_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.streamscribe_bucket.arn,
          "${aws_s3_bucket.streamscribe_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "streamscribe_profile" {
  name = "streamscribe_profile"
  role = aws_iam_role.streamscribe_role.name
}

# Key pair for SSH access
resource "aws_key_pair" "streamscribe_key" {
  key_name   = "streamscribe-key"
  public_key = file("~/.ssh/id_ed25519.pub")  # Make sure this key exists
}

# EC2 Instance
resource "aws_instance" "streamscribe_instance" {
  ami           = "ami-04dd23e62ed049936"  # Ubuntu 20.04 LTS - change according to your region
  instance_type = "t2.micro"  # Adjusted for cost optimization

  vpc_security_group_ids = [aws_security_group.streamscribe_sg.id]
  subnet_id              = aws_subnet.streamscribe_subnet.id
  iam_instance_profile   = aws_iam_instance_profile.streamscribe_profile.name
  key_name               = aws_key_pair.streamscribe_key.key_name

  root_block_device {
    volume_size = 8  # Adjusted for cost optimization
  }

  # Initial setup script
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y python3-pip default-jdk
              pip3 install pyspark streamlit boto3 openai yt-dlp

              # Auto-shutdown script
              echo "0 19 * * * root /usr/sbin/shutdown -h now" | tee -a /etc/crontab
              EOF
  
     # Wait for instance to be ready before provisioning
  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_ed25519")
    host        = self.public_ip
  }

  # Copy the video_downloader.py file
  provisioner "file" {
    source      = "video_downloader.py"
    destination = "/tmp/video_downloader.py"
  }

  # Set up the application after copying file
  provisioner "remote-exec" {
    inline = [
      # Ensure the directory exists
      "sudo mkdir -p /opt/streamscribe",
      "sudo chown ubuntu:ubuntu /opt/streamscribe",
      "chmod 755 /opt/streamscribe",
      "chmod +x /tmp/video_downloader.py",
      "mv /tmp/video_downloader.py /opt/streamscribe/video_downloader.py",
      "echo 'Python script has been copied and permissions set.'"
    ]
  }

  tags = {
    Name = "streamscribe-instance"
  }
}

# Outputs
output "instance_public_ip" {
  value = aws_instance.streamscribe_instance.public_ip
}

output "s3_bucket_name" {
  value = aws_s3_bucket.streamscribe_bucket.id
}

output "important_notice" {
  value = "Note: The S3 bucket is configured with prevent_destroy. It will not be deleted when running terraform destroy."
}

# Additional output for SSH command
output "ssh_command" {
  value = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_instance.streamscribe_instance.public_ip}"
}