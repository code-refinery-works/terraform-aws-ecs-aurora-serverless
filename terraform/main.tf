terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket         = "tfstate-ecs-api"
    key            = "ecs-api/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "tfstate-lock"
  }
}

provider "aws" { region = var.region }

locals {
  name = "${var.project}-${var.env}"
  azs  = ["${var.region}a", "${var.region}c"]
  tags = { Project = var.project, Env = var.env, ManagedBy = "terraform" }
}

# ── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

# Subnets (public/private/db × 2AZ)
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = local.azs[count.index]
  tags              = merge(local.tags, { Name = "${local.name}-public-${count.index}" })
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 4)
  availability_zone = local.azs[count.index]
  tags              = merge(local.tags, { Name = "${local.name}-private-${count.index}" })
}
resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  availability_zone = local.azs[count.index]
  tags              = merge(local.tags, { Name = "${local.name}-db-${count.index}" })
}

# NAT Gateway
resource "aws_eip" "nat" {
  count  = var.single_nat ? 1 : 2
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name}-nat-eip-${count.index}" })
}
resource "aws_nat_gateway" "main" {
  count         = var.single_nat ? 1 : 2
  subnet_id     = aws_subnet.public[count.index].id
  allocation_id = aws_eip.nat[count.index].id
  tags          = merge(local.tags, { Name = "${local.name}-nat-${count.index}" })
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; gateway_id = aws_internet_gateway.main.id }
  tags   = merge(local.tags, { Name = "${local.name}-rt-public" })
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table" "private" {
  count  = var.single_nat ? 1 : 2
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; nat_gateway_id = aws_nat_gateway.main[count.index].id }
  tags   = merge(local.tags, { Name = "${local.name}-rt-private-${count.index}" })
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.single_nat ? 0 : count.index].id
}

# ── Security Groups ───────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "${local.name}-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags   = merge(local.tags, { Name = "${local.name}-alb-sg" })
}
resource "aws_security_group" "ecs" {
  name   = "${local.name}-ecs-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = var.container_port; to_port = var.container_port; protocol = "tcp"; security_groups = [aws_security_group.alb.id] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags   = merge(local.tags, { Name = "${local.name}-ecs-sg" })
}
resource "aws_security_group" "db" {
  name   = "${local.name}-db-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 5432; to_port = 5432; protocol = "tcp"; security_groups = [aws_security_group.ecs.id] }
  tags   = merge(local.tags, { Name = "${local.name}-db-sg" })
}

# ── Aurora Serverless v2 ──────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnet"
  subnet_ids = aws_subnet.db[*].id
  tags       = local.tags
}
resource "aws_rds_cluster" "main" {
  cluster_identifier        = "${local.name}-aurora"
  engine                    = "aurora-postgresql"
  engine_mode               = "provisioned"
  engine_version            = "15.4"
  database_name             = var.db_name
  master_username           = "adminuser"
  manage_master_user_password = true
  db_subnet_group_name      = aws_db_subnet_group.main.name
  vpc_security_group_ids    = [aws_security_group.db.id]
  storage_encrypted         = true
  backup_retention_period   = var.backup_retention
  deletion_protection       = var.env == "prd"
  skip_final_snapshot       = var.env != "prd"
  serverlessv2_scaling_configuration { min_capacity = var.acu_min; max_capacity = var.acu_max }
  tags = local.tags
}
resource "aws_rds_cluster_instance" "main" {
  count                = 2
  identifier           = "${local.name}-aurora-${count.index}"
  cluster_identifier   = aws_rds_cluster.main.id
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.main.engine
  engine_version       = aws_rds_cluster.main.engine_version
  db_subnet_group_name = aws_db_subnet_group.main.name
  tags                 = local.tags
}

# ── IAM ──────────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "ecs_assume" {
  statement { actions = ["sts:AssumeRole"]; principals { type = "Service"; identifiers = ["ecs-tasks.amazonaws.com"] } }
}
resource "aws_iam_role" "exec" {
  name               = "${local.name}-ecs-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}
resource "aws_iam_role_policy" "task_ssm" {
  name   = "ecs-exec-ssm"
  role   = aws_iam_role.task.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"], Resource = "*" }] })
}

# ── ALB ──────────────────────────────────────────────────────────────────────
resource "aws_lb" "main" {
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  enable_deletion_protection = var.env == "prd"
  tags                       = local.tags
}
resource "aws_lb_target_group" "main" {
  name        = "${local.name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = var.health_check_path; healthy_threshold = 2; unhealthy_threshold = 3 }
  tags = local.tags
}
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn
  default_action    { type = "forward"; target_group_arn = aws_lb_target_group.main.arn }
}

# ── ECS ──────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name}"
  retention_in_days = 30
  tags              = local.tags
}
resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"
  setting { name = "containerInsights"; value = "enabled" }
  tags = local.tags
}
resource "aws_ecs_task_definition" "main" {
  family                   = "${local.name}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode([{
    name      = "api"
    image     = var.container_image
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    secrets   = [{ name = "DB_SECRET", valueFrom = aws_rds_cluster.main.master_user_secret[0].secret_arn }]
    environment = [{ name = "DB_HOST", value = aws_rds_cluster.main.endpoint }, { name = "DB_NAME", value = var.db_name }]
    logConfiguration = { logDriver = "awslogs", options = { "awslogs-group" = aws_cloudwatch_log_group.ecs.name, "awslogs-region" = var.region, "awslogs-stream-prefix" = "api" } }
  }])
}
resource "aws_ecs_service" "main" {
  name                   = "${local.name}-service"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.main.arn
  desired_count          = var.min_tasks
  launch_type            = "FARGATE"
  enable_execute_command = true
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }
  load_balancer { target_group_arn = aws_lb_target_group.main.arn; container_name = "api"; container_port = var.container_port }
  lifecycle { ignore_changes = [desired_count] }
}

# Auto Scaling
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_tasks
  min_capacity       = var.min_tasks
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value = 60.0
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}