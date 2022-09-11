module "application" {
  source  = "github.com/massdriver-cloud/terraform-modules//massdriver-application"
  name    = module.application.params.md_metadata.name_prefix
  service = "function"
}

resource "google_cloud_run_service" "main" {
  name     = module.application.params.md_metadata.name_prefix
  location = var.location

  template {
    metadata {
      annotations = {
        # Use the VPC Connector
        "run.googleapis.com/vpc-access-connector" = google_vpc_access_connector.connector.name
        # all egress from the service should go through the VPC Connector
        "run.googleapis.com/vpc-access-egress" = "all-traffic"
        "autoscaling.knative.dev/maxScale"     = "${var.max_instances}"
      }

    }

    spec {
      service_account_name = module.application.id
      containers {
        image = var.container_image
        dynamic "env" {
          for_each = module.application.envs
          content {
            name  = env.key
            value = env.value
          }
        }
      }
    }
  }
  metadata {
    annotations = {
      # For valid annotation values and descriptions, see
      # https://cloud.google.com/sdk/gcloud/reference/run/deploy#--ingress
      "run.googleapis.com/ingress" = "internal-and-cloud-load-balancing"
    }
  }
}