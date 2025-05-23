/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */





locals {
  nextauth_url                   = "http://${google_compute_global_address.default.address}"
  has_default_firestore_database = length(data.google_cloud_asset_resources_search_all.default_firestore_database.results) > 0 ? true : false
}

### GCS bucket ###

resource "random_id" "bucket_prefix" {
  byte_length = 6
}

resource "random_id" "service_account_prefix" {
  byte_length = 3
}

resource "google_storage_bucket" "default" {
  project                     = var.project_id
  name                        = "${var.deployment_name}-bucket-${random_id.bucket_prefix.hex}"
  location                    = "US"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = var.labels
}

resource "google_storage_bucket_iam_member" "default" {
  bucket = google_storage_bucket.default.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_object" "icons" {
  for_each     = fileset(path.module, "google-cloud-icons/*.svg")
  name         = each.value
  source       = "${path.module}/${each.value}"
  content_type = "image/svg+xml"
  bucket       = google_storage_bucket.default.name
}

resource "google_compute_backend_bucket" "default" {
  project     = var.project_id
  name        = "${var.deployment_name}-backend-bucket"
  description = "Backend bucket for ${var.deployment_name}"
  bucket_name = google_storage_bucket.default.name
  enable_cdn  = true
  cdn_policy {
    cache_mode        = "CACHE_ALL_STATIC"
    client_ttl        = 3600
    default_ttl       = 3600
    max_ttl           = 86400
    negative_caching  = true
    serve_while_stale = 86400
  }
  depends_on = [
    time_sleep.project_services,
    time_sleep.cloud_run_v2_service
  ]
}

### Secret Manager resources ###

resource "random_id" "nextauth_secret" {
  byte_length = 32
}

resource "google_secret_manager_secret" "nextauth_secret" {
  project   = var.project_id
  secret_id = "${var.deployment_name}-nextauth-secret"
  replication {
    auto {}
  }
  labels = var.labels
  depends_on = [
    time_sleep.project_services
  ]
}

resource "google_secret_manager_secret_version" "nextauth_secret" {
  secret      = google_secret_manager_secret.nextauth_secret.id
  secret_data = random_id.nextauth_secret.b64_std
  depends_on = [
    google_secret_manager_secret.nextauth_secret
  ]
}

resource "time_sleep" "nextauth_secret" {
  depends_on = [
    google_secret_manager_secret_version.nextauth_secret
  ]

  create_duration = "15s"
}

resource "google_secret_manager_secret_iam_binding" "nextauth_secret" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.nextauth_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  members = [
    "serviceAccount:${google_service_account.cloud_run.email}",
  ]
  depends_on = [
    google_secret_manager_secret.nextauth_secret
  ]
}

### Cloud Run service resources and network endpoint group ###
#### Service Account
resource "google_service_account" "cloud_run" {
  project      = var.project_id
  account_id   = "run-service-account-${random_id.service_account_prefix.hex}"
  display_name = "${var.deployment_name} Cloud Run service Service Account."
  depends_on = [
    time_sleep.project_services
  ]
}

#### Cloud Run IAM
resource "google_project_iam_member" "run_datastore_owner" {
  project = var.project_id
  role    = "roles/datastore.owner"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_cloud_run_v2_service" "default" {
  project  = var.project_id
  name     = var.deployment_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  deletion_protection = false

  template {
    containers {
      image = var.initial_run_image
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name = "NEXTAUTH_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.nextauth_secret.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "NEXTAUTH_URL"
        value = local.nextauth_url
      }
    }
    service_account = google_service_account.cloud_run.email
  }
  labels = var.labels
  depends_on = [
    time_sleep.nextauth_secret
  ]
}

resource "time_sleep" "cloud_run_v2_service" {
  depends_on = [
    google_cloud_run_v2_service.default
  ]

  create_duration = "45s"
}

data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}

resource "google_cloud_run_service_iam_policy" "noauth" {
  project  = google_cloud_run_v2_service.default.project
  location = google_cloud_run_v2_service.default.location
  service  = google_cloud_run_v2_service.default.name

  policy_data = data.google_iam_policy.noauth.policy_data
  depends_on = [
    time_sleep.cloud_run_v2_service
  ]
}

resource "google_compute_region_network_endpoint_group" "default" {
  project               = var.project_id
  region                = var.region
  name                  = "${var.deployment_name}-network-endpoint-group"
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.default.name
  }
  depends_on = [
    time_sleep.project_services,
    time_sleep.cloud_run_v2_service
  ]
}

### External loadbalancer ###
resource "google_compute_global_address" "default" {
  project = var.project_id
  name    = "${var.deployment_name}-reserved-ip"
  depends_on = [
    time_sleep.project_services
  ]
}

resource "google_compute_url_map" "default" {
  project         = var.project_id
  name            = "${var.deployment_name}-http-load-balancer"
  default_service = google_compute_backend_service.default.id
  host_rule {
    hosts        = [google_compute_global_address.default.address]
    path_matcher = "ip4addr"
  }
  path_matcher {
    name            = "ip4addr"
    default_service = google_compute_backend_service.default.id
    path_rule {
      paths   = ["/google-cloud-icons/*"]
      service = google_compute_backend_bucket.default.id
    }
  }
  depends_on = [
    time_sleep.cloud_run_v2_service
  ]
}

resource "google_compute_backend_service" "default" {
  project               = var.project_id
  name                  = "${var.deployment_name}-run-backend-service"
  port_name             = "http"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  enable_cdn            = true
  backend {
    group = google_compute_region_network_endpoint_group.default.id
  }
  log_config {
    enable      = true
    sample_rate = 1
  }
  cdn_policy {
    cache_mode                   = "CACHE_ALL_STATIC"
    client_ttl                   = "3600"
    default_ttl                  = "3600"
    max_ttl                      = "86400"
    negative_caching             = true
    serve_while_stale            = "86400"
    signed_url_cache_max_age_sec = 0
    cache_key_policy {
      include_host           = true
      include_http_headers   = []
      include_named_cookies  = []
      include_protocol       = true
      include_query_string   = true
      query_string_blacklist = []
      query_string_whitelist = []
    }
  }
}

resource "google_compute_target_http_proxy" "default" {
  project = var.project_id
  name    = "${var.deployment_name}-http-proxy"
  url_map = google_compute_url_map.default.id
}

resource "google_compute_global_forwarding_rule" "http" {
  project               = var.project_id
  name                  = "${var.deployment_name}-http-forwarding-rule"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
  ip_address            = google_compute_global_address.default.id
  labels                = var.labels
}

# It may take more than 2 minutes for the newly provisioned load balancer
# to forward requests to the Cloud Run service.  The following data source
# allows for terraform apply to finish running when the end-point resolves

data "http" "load_balancer_warm_up" {
  url = "http://${google_compute_global_address.default.address}/"
  # Attempt retry every 20 seconds 17 times, totaling to a 6 minute timeout.
  retry {
    attempts     = 17
    max_delay_ms = 20000
    min_delay_ms = 20000
  }
  # Begin trying after load balancer resources are created.
  depends_on = [
    google_compute_global_address.default,
    google_compute_url_map.default,
    google_compute_backend_service.default,
    google_compute_target_http_proxy.default,
    google_compute_global_forwarding_rule.http
  ]
}

### Firestore ###

# The following checks Asset Inventory for an existing Firestore database
data "google_cloud_asset_resources_search_all" "default_firestore_database" {
  provider = google-beta
  scope    = "projects/${var.project_id}"
  query    = "displayName:(default)"
  asset_types = [
    "firestore.googleapis.com/Database"
  ]
}

# If a Firestore database exists on the project, Terraform will skip this resource
resource "google_firestore_database" "database" {
  count                       = var.init_firestore && !local.has_default_firestore_database ? 1 : 0
  project                     = var.project_id
  name                        = "(default)"
  location_id                 = "nam5"
  type                        = "FIRESTORE_NATIVE"
  concurrency_mode            = "PESSIMISTIC"
  app_engine_integration_mode = "DISABLED"
  depends_on = [
    time_sleep.project_services
  ]
}
