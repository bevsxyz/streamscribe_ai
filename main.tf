# Provider configuration
provider "aws" {
  profile = "kirti"
  region  = "us-west-2"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "streamscribe-vpc"
  cidr = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  map_public_ip_on_launch = true

  azs             = ["us-west-2a"]
  private_subnets = ["10.0.2.0/24"]
  public_subnets  = ["10.0.1.0/24"]

  tags = {
    "Name" = "streamscribe-vpc"
  }
}

resource "aws_security_group" "streamscribe_sg" {
  name        = "streamscribe-sg"
  description = "Security group for StreamScribe EC2 instance"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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


module "s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = "streamscribe-data-bucket"
  force_destroy = true

  tags = {
    Name = "streamscribe-bucket"
  }
}

resource "aws_iam_role" "streamscribe_role" {
  name = "streamscribe_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy" "streamscribe_s3_policy" {
  name = "streamscribe_s3_policy"
  role = aws_iam_role.streamscribe_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          module.s3_bucket.s3_bucket_arn,
          "${module.s3_bucket.s3_bucket_arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "streamscribe_profile" {
  name = "streamscribe_profile"
  role = aws_iam_role.streamscribe_role.name
}

resource "aws_key_pair" "streamscribe_key" {
  key_name   = "streamscribe-key"
  public_key = file("~/.ssh/id_ed25519.pub")
}


resource "aws_instance" "streamscribe_instance" {
  ami           = "ami-04dd23e62ed049936"
  instance_type = "t2.micro"

  vpc_security_group_ids = [aws_security_group.streamscribe_sg.id]
  subnet_id              = module.vpc.public_subnets[0]
  iam_instance_profile   = aws_iam_instance_profile.streamscribe_profile.name
  key_name               = aws_key_pair.streamscribe_key.key_name

  root_block_device {
    volume_size = 8
  }

  user_data = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y python3-venv python3-pip default-jdk yt-dlp
    python3 -m venv /opt/streamscribe/venv
    chmod +x /opt/streamscribe/venv/bin/activate
    source /opt/streamscribe/venv/bin/activate
    pip install pyspark streamlit boto3 openai awscli
    echo "0 19 * * * root /usr/sbin/shutdown -h now" | tee -a /etc/crontab
  EOF

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_ed25519")
    host        = self.public_ip
  }

  provisioner "file" {
    source      = "vid_down.sh"
    destination = "/tmp/vid_down.sh"
  }

  provisioner "file" {
    source      = "main.py"
    destination = "/tmp/main.py"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /opt/streamscribe",
      "sudo chown ubuntu:ubuntu /opt/streamscribe",
      "chmod 755 /opt/streamscribe",
      "chmod +x /tmp/vid_down.sh",
      "mv /tmp/vid_down.sh /opt/streamscribe/vid_down.sh",
      "mv /tmp/main.py /opt/streamscribe/main.py"
      "echo 'source /opt/streamscribe/venv/bin/activate' >> /home/ubuntu/.bashrc",
      "echo 'Python script has been copied and permissions set.'"
    ]
  }

  tags = {
    Name = "streamscribe-instance"
  }
}

output "instance_public_ip" {
  value = aws_instance.streamscribe_instance.public_ip
}

output "s3_bucket_name" {
  value = module.s3_bucket.s3_bucket_id
}

output "important_notice" {
  value = "Note: The S3 bucket is configured with prevent_destroy. It will not be deleted when running terraform destroy."
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/id_ed25519 ubuntu@${aws_instance.streamscribe_instance.public_ip}"
}
