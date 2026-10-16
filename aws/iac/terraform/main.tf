terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # For team use, keep state in an encrypted S3 bucket (state contains the generated DB password):
  # backend "s3" { bucket = "<state-bucket>" key = "todo-app/terraform.tfstate" region = "ap-south-1" encrypt = true }
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = var.project, ManagedBy = "terraform" } }
}

data "aws_caller_identity" "me" {}

# ponytail: default VPC keeps the footprint small; a dedicated VPC with private subnets is the upgrade path
data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ------------------------------------------------------------ security groups
resource "aws_security_group" "ec2" {
  name        = "${var.project}-ec2"
  description = "Todo app host"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Web app (nginx -> backend)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH, admin only (break-glass; SSM is preferred)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  ingress {
    description = "Grafana, admin only"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  egress {
    description = "Image pulls, SSM, Cohere/Slack APIs, RDS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-rds"
  description = "MySQL reachable only from the app host"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL from EC2 security group only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
}

# ------------------------------------------------------------ RDS (MySQL)
resource "random_password" "db" {
  length           = 24
  override_special = "-_.~!" # nothing that needs quoting in .env / JDBC
}

resource "aws_db_subnet_group" "this" {
  name       = var.project
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "mysql" {
  identifier                 = "${var.project}-db"
  engine                     = "mysql"
  engine_version             = "8.0"
  instance_class             = var.db_instance_class
  allocated_storage          = 20
  storage_type               = "gp3"
  storage_encrypted          = true
  db_name                    = "todo_db"
  username                   = "todoapp"
  password                   = random_password.db.result
  db_subnet_group_name       = aws_db_subnet_group.this.name
  vpc_security_group_ids     = [aws_security_group.rds.id]
  publicly_accessible        = false
  multi_az                   = var.db_multi_az
  backup_retention_period    = var.db_backup_retention_days
  backup_window              = "20:00-21:00"
  maintenance_window         = "sun:21:30-sun:22:30"
  auto_minor_version_upgrade = true
  deletion_protection        = false # assessment environment; set true in real production
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.project}-db-final"
}

# ------------------------------------------------------------ app config in SSM Parameter Store
# deploy.sh renders every parameter under /todo-app/ into the host's .env (name = env var).
locals {
  plain_params = {
    SPRING_DATASOURCE_URL      = "jdbc:mysql://${aws_db_instance.mysql.endpoint}/todo_db"
    SPRING_DATASOURCE_USERNAME = aws_db_instance.mysql.username
    IMAGE_REPO                 = var.dockerhub_username
  }
  # Third-party secrets: created as placeholders, real values set out-of-band (see aws-setup.md)
  external_secrets = ["COHERE_API_KEY", "SLACK_WEBHOOK_URL", "ALERT_SLACK_WEBHOOK_URL"]
}

resource "aws_ssm_parameter" "plain" {
  for_each = local.plain_params
  name     = "/${var.project}/${each.key}"
  type     = "String"
  value    = each.value
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project}/SPRING_DATASOURCE_PASSWORD"
  type  = "SecureString"
  value = random_password.db.result
}

resource "random_password" "grafana" {
  length  = 20
  special = false
}

resource "aws_ssm_parameter" "grafana_password" {
  name  = "/${var.project}/GRAFANA_ADMIN_PASSWORD"
  type  = "SecureString"
  value = random_password.grafana.result
}

resource "aws_ssm_parameter" "external" {
  for_each = toset(local.external_secrets)
  name     = "/${var.project}/${each.key}"
  type     = "SecureString"
  value    = "CHANGE_ME"
  lifecycle { ignore_changes = [value] }
}

# ------------------------------------------------------------ EC2 instance role (no static keys)
resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

# SSM agent: Run Command (CI deploys) + Session Manager (shell without opening port 22)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_app_params" {
  name = "read-app-parameters"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParametersByPath", "ssm:GetParameters", "ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter/${var.project}*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2"
  role = aws_iam_role.ec2.name
}

# ------------------------------------------------------------ EC2 host
resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.key_name
  user_data              = templatefile("${path.module}/user_data.sh.tftpl", { repo_url = var.repo_url })

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project}-host" }

  lifecycle { ignore_changes = [ami, user_data] }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
}

# ------------------------------------------------------------ GitHub Actions deploy role (OIDC)
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_github_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

locals {
  oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.me.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_deploy" {
  name = "${var.project}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # only the production environment job of this repo can assume the role
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:environment:production"
        }
      }
    }]
  })
  depends_on = [aws_iam_openid_connect_provider.github]
}

# Least privilege: run the stock shell document on this one instance, and read the result
resource "aws_iam_role_policy" "github_deploy" {
  name = "ssm-deploy-to-app-host"
  role = aws_iam_role.github_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          aws_instance.app.arn,
          "arn:aws:ssm:${var.region}::document/AWS-RunShellScript",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
    ]
  })
}
