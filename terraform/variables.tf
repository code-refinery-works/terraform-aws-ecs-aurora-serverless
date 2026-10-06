variable "project"              { type = string; default = "myapi" }
variable "env"                  { type = string; default = "dev"; validation { condition = contains(["dev","prd"], var.env); error_message = "env must be dev or prd." } }
variable "region"               { type = string; default = "ap-northeast-1" }
variable "vpc_cidr"             { type = string; default = "10.0.0.0/20" }
variable "single_nat"           { type = bool;   default = true;  description = "true=dev(1台)/false=prd(2台)" }
variable "db_name"              { type = string; default = "apidb" }
variable "backup_retention"     { type = number; default = 7 }
variable "acu_min"              { type = number; default = 0.5 }
variable "acu_max"              { type = number; default = 8 }
variable "container_image"      { type = string; description = "ECR image URI e.g. 123456789.dkr.ecr.ap-northeast-1.amazonaws.com/myapi:latest" }
variable "container_port"       { type = number; default = 8080 }
variable "task_cpu"             { type = string; default = "512" }
variable "task_memory"          { type = string; default = "1024" }
variable "min_tasks"            { type = number; default = 2 }
variable "max_tasks"            { type = number; default = 10 }
variable "health_check_path"    { type = string; default = "/health" }
variable "acm_certificate_arn"  { type = string; description = "ACM certificate ARN for HTTPS listener" }