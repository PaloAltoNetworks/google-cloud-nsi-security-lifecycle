output "PRODUCER_PROJECT" {
  value = var.project_id
}


# output "DEPLOYMENT_GROUP" {
#   description = "The ID of the producer deployment group (either Intercept or Mirroring)."
#   value       = var.mirroring_mode ? google_network_security_mirroring_deployment_group.main[0].id : google_network_security_intercept_deployment_group.main[0].id
# }
