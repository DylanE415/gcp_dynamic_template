provider "google" {
  credentials = file(var.key_path)
  project     = var.project_id
  region      = "us-central1"
}

provider "google-beta" {
  credentials = file(var.key_path)
  project     = var.project_id
  region      = "us-central1"
}
