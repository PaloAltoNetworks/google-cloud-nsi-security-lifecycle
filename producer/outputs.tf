output "PRODUCER_PROJECT" {
  value = var.project_id
}


output "DEPLOYMENT_GROUP" {
  description = "The ID of the producer deployment group (either Intercept or Mirroring)."
  value       = var.mirroring_mode ? google_network_security_mirroring_deployment_group.main[0].id : google_network_security_intercept_deployment_group.main[0].id
}

output "BOOTSTRAP_BUCKET" {
  description = "The name of the bootstrap GCS bucket."
  value       = module.bootstrap.bucket_name
}

output "MGMT_VPC" {
  description = "The name of the management VPC network."
  value       = google_compute_network.mgmt.name
}

output "DATA_VPC" {
  description = "The name of the dataplane VPC network."
  value       = google_compute_network.data.name
}
