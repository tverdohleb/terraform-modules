locals {
  region             = var.ecs_cluster.specs.aws.region
  vpc_id             = element(split("/", var.ecs_cluster.data.infrastructure.vpc.data.infrastructure.arn), 1)
  private_subnet_ids = toset([for subnet in var.ecs_cluster.data.infrastructure.vpc.data.infrastructure.private_subnets : element(split("/", subnet["arn"]), 1)])
  ecs_cluster_arn    = var.ecs_cluster.data.infrastructure.arn
  ecs_cluster_name   = element(split("/", var.ecs_cluster.data.infrastructure.arn), 1)
}

module "application" {
  source  = "github.com/massdriver-cloud/terraform-modules//massdriver-application?ref=36f3357"
  name    = var.md_metadata.name_prefix
  service = "container"
}

resource "aws_ecs_service" "main" {
  name            = var.md_metadata.name_prefix
  cluster         = local.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.autoscaling.min_replicas
  launch_type     = var.launch_type

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [aws_security_group.main.id]
  }

  dynamic "load_balancer" {
    for_each = local.container_ingress_port_map
    content {
      target_group_arn = aws_lb_target_group.main[load_balancer.key].arn
      container_name   = load_balancer.value.container_name
      container_port   = load_balancer.value.container_port
    }
  }

  lifecycle {
    ignore_changes = [
      desired_count
    ]
  }
}

resource "aws_ecs_task_definition" "main" {
  family                   = var.md_metadata.name_prefix
  execution_role_arn       = aws_iam_role.execution_role.arn
  requires_compatibilities = [var.launch_type]
  network_mode             = "awsvpc"

  memory = var.task_memory
  cpu    = var.task_cpu

  task_role_arn = module.application.id

  container_definitions = jsonencode(
    [for container in var.containers :
      {
        name       = container.name
        image      = "${container.image_repository}:${container.image_tag}"
        cpu        = lookup(container, "cpu", null)
        memory     = lookup(container, "memory", null)
        entrypoint = lookup(container, "entrypoint", null)
        command    = lookup(container, "command", null)
        essential  = true

        environment = [for name, value in module.application.envs :
          {
            name  = name
            value = value
          }
        ]

        portMappings = [for port in container.ports :
          {
            containerPort = port.container_port
          }
        ]

        logConfiguration = {
          logDriver = var.logging.driver
          options   = lookup(local.logging_options, var.logging.driver, {})
        }
      }
  ])
}

resource "aws_appautoscaling_target" "main" {
  max_capacity       = var.autoscaling.max_replicas
  min_capacity       = var.autoscaling.min_replicas
  resource_id        = "service/${local.ecs_cluster_name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.md_metadata.name_prefix}-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.main.resource_id
  scalable_dimension = aws_appautoscaling_target.main.scalable_dimension
  service_namespace  = aws_appautoscaling_target.main.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = var.autoscaling.target_cpu_percent
  }
}
