variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "todo-app"
}

variable "admin_cidr" {
  description = "Your public IP in CIDR form (e.g. 203.0.113.7/32). Only this can reach SSH and Grafana."
  type        = string
}

variable "github_repo" {
  description = "owner/name of the GitHub repo allowed to deploy (OIDC trust)."
  type        = string
}

variable "repo_url" {
  description = "HTTPS clone URL of the (public) repo the EC2 host checks out."
  type        = string
}

variable "dockerhub_username" {
  description = "Docker Hub namespace the images are pushed to."
  type        = string
}

variable "instance_type" {
  description = "t3.small (2 GiB) fits app + monitoring; t3.micro works with the 2 GiB swapfile but is tight."
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Optional EC2 key pair for break-glass SSH. SSM Session Manager is the primary access path."
  type        = string
  default     = null
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_multi_az" {
  description = "true for production HA (standby in a second AZ, automatic failover). Off by default to stay in free tier."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Automated backups + point-in-time restore window. Free-plan accounts may be capped at 1."
  type        = number
  default     = 1
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the token.actions.githubusercontent.com provider."
  type        = bool
  default     = true
}
