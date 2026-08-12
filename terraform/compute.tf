# Control 1 — Ephemeral compute: ECS Fargate
# Control 2 — Capability-dropped, read-only runtime
# Control 7 — Observability: CloudWatch logs + awslogs driver

resource "aws_cloudwatch_log_group" "agent" {
  # Control 7: explicit retention (never indefinite/unset)
  name              = "/ecs/${var.project_name}-agent"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "agent" {
  # Control 1: ephemeral Fargate compute — no EC2, no always-on server
  name = "${var.project_name}-agent"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_task_definition" "agent" {
  # Control 1: Fargate task definition (smallest practical size)
  # Control 2: readonly root FS, drop ALL capabilities, in-memory /tmp scratch
  family                   = "${var.project_name}-agent"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "agent"
      image     = var.container_image
      essential = true

      # Control 2: read-only root filesystem
      readonlyRootFilesystem = true

      linuxParameters = {
        # Control 2: drop all Linux capabilities
        capabilities = {
          drop = ["ALL"]
        }
        # Control 2: in-memory scratch at /tmp (tmpfs) — not a persistent writable volume.
        # On Fargate this is the supported in-memory mount when the root FS is read-only.
        tmpfs = [
          {
            containerPath = "/tmp"
            size          = var.tmpfs_size_mib
            mountOptions  = ["rw", "noexec", "nosuid", "nodev"]
          }
        ]
      }

      logConfiguration = {
        # Control 7: awslogs driver pointed at the retention-limited log group
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "agent"
        }
      }
    }
  ])
}
