# VARIABLES

locals {
  deploy_ui_cf_name    = "deploy-ui-gcs"
  deploy_ui_topic      = "deploy-ui-gcs"
  artifact_bucket_name = "gh-artifacts"
  ui_name              = "ui"
  runner_api_name      = "runner-api"
  example_api_name     = "example-api"
  example_db_name      = "example-db"
}

variable "project" {
  type = string
}
variable "region" {
  type = string
}
variable "zone" {
  type = string
}
variable "credentials" {
  type = string
}
variable "cloud_run_location" {
  type = string
}
variable "gcs_location" {
  type = string
}
variable "gh_deploy_sa" {
  type = string
}
variable "runner_api_image" {
  type = string
}
variable "example_api_image" {
  type = string
}
variable "ui_build_revision" {
  type = string
}
variable "ui_dns_name" {
  type = string
}
variable "example_db_api_user_password" {
  type      = string
  sensitive = true
}
variable "nr_license_key" {
  type      = string
  sensitive = true
}

# TF BACKEND

terraform {
  backend "gcs" {
    bucket      = "slam-lang-tf-state"
    prefix      = "terraform/state"
    credentials = "sa.json"
  }
}

provider "google" {
  project     = var.project
  region      = var.region
  zone        = var.zone
  credentials = var.credentials
}

# DEPLOYMENT INFRA

resource "google_storage_bucket" "gh-artifacts" {
  name          = "${var.project}-${local.artifact_bucket_name}"
  location      = var.gcs_location
  force_destroy = true

  uniform_bucket_level_access = true
}

resource "google_pubsub_schema" "deploy-ui-gcs" {
  name       = "${local.deploy_ui_topic}-schema"
  type       = "AVRO"
  definition = <<-EOT
    {
      "type": "record",
      "name": "Avro",
      "fields": [
        {
          "name": "revision",
          "type": "string"
        }
      ]
    }
  EOT
}

resource "google_pubsub_topic" "deploy-ui-gcs" {
  name = local.deploy_ui_topic

  depends_on = [google_pubsub_schema.deploy-ui-gcs]
  schema_settings {
    schema   = "projects/${var.project}/schemas/${google_pubsub_schema.deploy-ui-gcs.name}"
    encoding = "JSON"
  }
}

resource "google_pubsub_schema" "deploy-ui-gcs-result" {
  name       = "${local.deploy_ui_topic}-result-schema"
  type       = "AVRO"
  definition = <<-EOT
    {
      "type": "record",
      "name": "Avro",
      "fields": [
        {
          "name": "revision",
          "type": "string"
        },
        {
          "name": "ok",
          "type": "boolean"
        }
      ]
    }
  EOT
}

resource "google_pubsub_topic" "deploy-ui-gcs-result" {
  name = "${local.deploy_ui_topic}-result"

  depends_on = [google_pubsub_schema.deploy-ui-gcs-result]
  schema_settings {
    schema   = "projects/${var.project}/schemas/${google_pubsub_schema.deploy-ui-gcs-result.name}"
    encoding = "JSON"
  }
}

resource "google_pubsub_subscription" "deploy-ui-gcs-result" {
  name  = "${local.deploy_ui_topic}-result-sub"
  topic = google_pubsub_topic.deploy-ui-gcs-result.name

  message_retention_duration = "604800s" # 7 days
  retain_acked_messages      = false

  ack_deadline_seconds = 20

  expiration_policy {
    ttl = ""
  }
  retry_policy {
    minimum_backoff = "10s"
  }

  enable_message_ordering = false
}

resource "null_resource" "cloud-function-deploy-ui-gcs" {
  triggers = {
    version         = jsondecode(file("deploy-ui-gcs/package.json")).version
    name            = local.deploy_ui_cf_name
    region          = var.cloud_run_location
    topic           = local.deploy_ui_topic
    service-account = var.gh_deploy_sa
  }

  depends_on = [
    google_storage_bucket.gh-artifacts,
    google_pubsub_topic.deploy-ui-gcs,
    google_pubsub_subscription.deploy-ui-gcs-result,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      cd deploy-ui-gcs
      gcloud functions deploy ${self.triggers.name} \
        --region ${self.triggers.region} \
        --trigger-topic ${self.triggers.topic} \
        --service-account=${self.triggers.service-account} \
        --runtime=nodejs16
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      cd deploy-ui-gcs
      gcloud functions delete ${self.triggers.name} \
        --region ${self.triggers.region} \
    EOT
  }
}

# FRONTEND UI

resource "google_storage_bucket" "ui" {
  name          = "${var.project}-${local.ui_name}"
  location      = var.gcs_location
  force_destroy = true

  uniform_bucket_level_access = true

  website {
    main_page_suffix = "index.html"
  }
  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    response_header = ["*"]
    max_age_seconds = 3600
  }
}

data "google_iam_policy" "gcs_allUsers_viewer" {
  binding {
    role = "roles/storage.objectViewer"
    members = [
      "allUsers",
    ]
  }
}

resource "google_storage_bucket_iam_policy" "ui" {
  bucket      = google_storage_bucket.ui.name
  policy_data = data.google_iam_policy.gcs_allUsers_viewer.policy_data
}

resource "null_resource" "ui-content" {
  triggers = {
    ui_build_revision = var.ui_build_revision
  }

  depends_on = [
    null_resource.cloud-function-deploy-ui-gcs,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      which npm
      cd deploy-ui-gcs
      npm run deploy "${var.ui_build_revision}"
    EOT
  }
}

resource "google_compute_backend_bucket" "ui" {
  name        = local.ui_name
  description = ""
  bucket_name = google_storage_bucket.ui.name
  enable_cdn  = false
}

resource "google_compute_url_map" "ui" {
  name            = local.ui_name
  project         = var.project
  provider        = google-beta
  default_service = google_compute_backend_bucket.ui.id
}

resource "google_compute_managed_ssl_certificate" "ui" {
  name = local.ui_name

  managed {
    domains = [var.ui_dns_name]
  }
}

resource "google_compute_target_https_proxy" "ui" {
  name             = local.ui_name
  project          = var.project
  url_map          = google_compute_url_map.ui.id
  ssl_certificates = [google_compute_managed_ssl_certificate.ui.id]
}

resource "google_compute_global_address" "ui" {
  provider = google-beta
  project  = var.project
  name     = local.ui_name
}

resource "google_compute_global_forwarding_rule" "ui" {
  name                  = local.ui_name
  project               = var.project
  provider              = google-beta
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "443"
  target                = google_compute_target_https_proxy.ui.id
  ip_address            = google_compute_global_address.ui.id
}

output "ui-ip" {
  value = google_compute_global_address.ui.address
}

output "ui-url" {
  value = "https://${var.ui_dns_name}"
}

# RUNNER API

resource "google_cloud_run_service" "runner-api" {
  name     = local.runner_api_name
  project  = var.project
  location = var.cloud_run_location

  template {
    spec {
      containers {
        image = var.runner_api_image
        env {
          name  = "NEWRELIC_LICENSE_KEY"
          value = var.nr_license_key
        }
      }
      timeout_seconds = 7 # interpreter timeout = 5
    }

    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale" = 3
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
}

data "google_iam_policy" "cloud_run_allUsers_invoker" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}

resource "google_cloud_run_service_iam_policy" "runner-api" {
  location = google_cloud_run_service.runner-api.location
  project  = google_cloud_run_service.runner-api.project
  service  = google_cloud_run_service.runner-api.name

  policy_data = data.google_iam_policy.cloud_run_allUsers_invoker.policy_data
}

# EXAMPLE API

resource "google_cloud_run_service" "example-api" {
  name     = local.example_api_name
  project  = var.project
  location = var.cloud_run_location

  template {
    spec {
      containers {
        image = var.example_api_image
        env {
          name  = "PGHOST"
          value = "/cloudsql/${google_sql_database_instance.example-db.connection_name}"
        }
        env {
          name  = "PGDATABASE"
          value = google_sql_database.example-db.name
        }
        env {
          name  = "PGUSER"
          value = local.example_api_name
        }
        env {
          name  = "PGPASSWORD"
          value = var.example_db_api_user_password
        }
        env {
          name  = "NEWRELIC_LICENSE_KEY"
          value = var.nr_license_key
        }
      }
      timeout_seconds = 5
    }

    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale"      = 3
        "run.googleapis.com/cloudsql-instances" = google_sql_database_instance.example-db.connection_name
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  depends_on = [
    google_sql_user.example-db
  ]
}

resource "google_cloud_run_service_iam_policy" "example-api" {
  location = google_cloud_run_service.example-api.location
  project  = google_cloud_run_service.example-api.project
  service  = google_cloud_run_service.example-api.name

  policy_data = data.google_iam_policy.cloud_run_allUsers_invoker.policy_data
}

# EXAMPLE DB

resource "google_sql_database_instance" "example-db" {
  name             = local.example_db_name
  database_version = "POSTGRES_14"
  region           = var.region

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    location_preference {
      zone = var.zone
    }
    disk_size = 10
    backup_configuration {
      enabled = false
    }
    ip_configuration {
      ipv4_enabled = true
    }
  }
}

resource "google_sql_database" "example-db" {
  name     = local.example_db_name
  instance = google_sql_database_instance.example-db.name
}

resource "google_sql_user" "example-db" {
  name     = local.example_api_name
  instance = google_sql_database_instance.example-db.name
  password = var.example_db_api_user_password
}
