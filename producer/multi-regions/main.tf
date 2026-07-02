# -------------------------------------------------------------------------------------
# Provider configuration
# -------------------------------------------------------------------------------------

terraform {
  required_version = "> 1.5, < 2.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.38.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.38.0"
    }
  }
}

provider "google" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true

  default_labels = {
    panw = "true"
  }
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true

  default_labels = {
    panw = "true"
  }
}


# -------------------------------------------------------------------------------------
# Localized variables
# -------------------------------------------------------------------------------------

locals {
  prefix                      = var.prefix != null && var.prefix != "" ? "${var.prefix}-" : ""
  public_key_path             = "${path.module}/bootstrap_files/gcp_key.pub"
  create_monitoring_dashboard = true
}


# -------------------------------------------------------------------------------------
# Create management and dataplane subnets and firewall rules in the existing VPCs.
# -------------------------------------------------------------------------------------

// Create management subnet
resource "google_compute_subnetwork" "mgmt" {
  name          = "${local.prefix}${var.region}-mgmt"
  ip_cidr_range = var.subnet_cidr_mgmt
  region        = var.region
  network       = var.mgmt_network_name
}

// Create dataplane subnet
resource "google_compute_subnetwork" "data" {
  name          = "${local.prefix}${var.region}-data"
  ip_cidr_range = var.subnet_cidr_data
  region        = var.region
  network       = var.data_network_name
}

// Firewall rule to allow management access
# resource "google_compute_firewall" "mgmt" {
#   name          = "${local.prefix}mgmt"
#   network       = var.mgmt_network_name
#   source_ranges = var.mgmt_allow_ips

#   allow {
#     protocol = "tcp"
#     ports    = ["443", "22", "3978"]
#   }
# }

# // Allow all traffic to firewall's dataplane VPC
# resource "google_compute_firewall" "data" {
#   name          = "${local.prefix}data"
#   network       = var.data_network_name
#   source_ranges = ["0.0.0.0/0"]

#   allow {
#     protocol = "all"
#     ports    = []
#   }
# }

# -------------------------------------------------------------------------------------
#  Create Cloud NAT for management VPC.
# -------------------------------------------------------------------------------------

// Create cloud router for cloud NAT.
resource "google_compute_router" "main" {
  name    = "${local.prefix}${var.region}-mgmt-router"
  network = var.mgmt_network_name
  region  = var.region
}

// Create cloud NAT for outbound internet access.
resource "google_compute_router_nat" "main" {
  name                               = "${local.prefix}${var.region}-mgmt-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}


# -------------------------------------------------------------------------------------
#  Create internal load balancer.
# -------------------------------------------------------------------------------------
// Create health check

resource "google_compute_region_health_check" "main" {
  name = "${local.prefix}${var.region}-panw-hc"
  https_health_check {
    port         = 443
    request_path = "/unauth/php/health.php"
  }
}

// Create backend service.
resource "google_compute_region_backend_service" "main" {
  provider      = google-beta
  name          = "${local.prefix}${var.region}-panw-lb"
  protocol      = "UDP"
  network       = var.data_network_name
  health_checks = [google_compute_region_health_check.main.self_link]

  backend {
    group          = google_compute_region_instance_group_manager.main.instance_group
    balancing_mode = "CONNECTION"
  }

  network_pass_through_lb_traffic_policy {
    zonal_affinity {
      spillover       = "ZONAL_AFFINITY_SPILL_CROSS_ZONE"
      spillover_ratio = 0.8
    }
  }
}

# -------------------------------------------------------------------------------------
#  Create forwarding rules
# -------------------------------------------------------------------------------------

// Create a forwarding rule for each zone within var.region 
resource "google_compute_forwarding_rule" "main" {
  for_each               = toset(data.google_compute_zones.available.names)
  name                   = "${local.prefix}panw-lb-rule-${each.key}"
  project                = var.project_id
  region                 = var.region
  load_balancing_scheme  = "INTERNAL"
  ip_protocol            = "UDP"
  ports                  = ["6081"]
  backend_service        = google_compute_region_backend_service.main.id
  ip_address             = cidrhost(var.subnet_cidr_data, 200 + index(data.google_compute_zones.available.names, each.key))
  subnetwork             = google_compute_subnetwork.data.id
  network                = var.data_network_name
  is_mirroring_collector = var.mirroring_mode ? true : false
}

# -------------------------------------------------------------------------------------
#  Create firewall service account, instance template, MIG, and autoscaler.
# -------------------------------------------------------------------------------------

// Retrieve zones within the region.
data "google_compute_zones" "available" {
  region = var.region
}

// Create service account for firewall
resource "google_service_account" "main" {
  account_id = "${local.prefix}${var.region}-panw-sa"
}

// Add roles to service account
resource "google_project_iam_member" "main" {
  for_each = var.roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.main.email}"
}

// Create instance template for the firewall
resource "google_compute_instance_template" "main" {
  name_prefix      = "${local.prefix}${var.region}-panw-template"
  machine_type     = var.machine_type
  min_cpu_platform = "Intel Cascade Lake"
  tags             = ["panw-tutorial"]
  can_ip_forward   = true

  metadata = {
    type                                  = "dhcp-client"
    dhcp-send-client-id                   = "yes"
    dhcp-accept-server-hostname           = "yes"
    dhcp-accept-server-domain             = "yes"
    vm-series-auto-registration-pin-id    = var.csp_pin_id
    vm-series-auto-registration-pin-value = var.csp_pin_value
    authcodes                             = var.csp_authcodes
    dns-primary                           = "169.254.169.254"
    vmseries-bootstrap-gce-storagebucket  = var.bootstrap_bucket
    # ssh-keys                             = "${file(local.public_key_path)}"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.mgmt.id
    dynamic "access_config" {
      for_each = var.mgmt_public_ip ? [1] : []
      content {}
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.data.id

  }

  disk {
    source_image = "https://www.googleapis.com/compute/v1/projects/paloaltonetworksgcp-public/global/images/${var.image_name}"
    disk_type    = "pd-ssd"
    auto_delete  = true
    boot         = true
  }

  lifecycle {
    create_before_destroy = true
  }

  service_account {
    email = google_service_account.main.email
    scopes = [
      "https://www.googleapis.com/auth/compute.readonly",
      "https://www.googleapis.com/auth/cloud.useraccounts.readonly",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  depends_on = [
    google_compute_router_nat.main
  ]
}


// Create regional instance group
resource "google_compute_region_instance_group_manager" "main" {
  name                      = "${local.prefix}${var.region}-panw-mig"
  base_instance_name        = "${local.prefix}${var.region}-panw-firewall"
  distribution_policy_zones = data.google_compute_zones.available.names

  version {
    instance_template = google_compute_instance_template.main.id
  }
}


// Configure autoscaling policy for instance group
resource "google_compute_region_autoscaler" "main" {
  name   = "${local.prefix}${var.region}-panw-autoscaler"
  target = google_compute_region_instance_group_manager.main.id

  autoscaling_policy {
    max_replicas    = var.max_firewalls
    min_replicas    = var.min_firewalls
    cooldown_period = 480
    dynamic "metric" {
      for_each = var.vmseries_metrics
      content {
        name   = metric.key
        type   = "GAUGE"
        target = metric.value.target
      }
    }
  }
}


# -------------------------------------------------------------------------------------
# Create Bastion Host
# -------------------------------------------------------------------------------------

resource "google_compute_instance" "bastion" {
  count        = var.create_bastion ? 1 : 0
  name         = "${local.prefix}${var.region}-bastion"
  machine_type = "e2-micro"
  zone         = data.google_compute_zones.available.names[0]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.mgmt.id
  }

  service_account {
    email  = google_service_account.main.email
    scopes = ["cloud-platform"]
  }
}

# -------------------------------------------------------------------------------------
# Create custom monitoring dashboard for VM-Series utilization metrics.
# -------------------------------------------------------------------------------------

# resource "google_monitoring_dashboard" "dashboard" {
#   count          = (local.create_monitoring_dashboard ? 1 : 0)
#   dashboard_json = templatefile("${path.root}/bootstrap_files/dashboard.json.tpl", { dashboard_name = "VM-Series Metrics" })

#   lifecycle {
#     ignore_changes = [
#       dashboard_json
#     ]
#   }
# }

// Create an intercept deployment for each zone within var.region
resource "google_network_security_intercept_deployment" "main" {
  provider                   = google-beta
  for_each                   = var.mirroring_mode ? {} : google_compute_forwarding_rule.main
  intercept_deployment_id    = "panw-deployment-${each.key}"
  location                   = each.key
  forwarding_rule            = each.value.id
  intercept_deployment_group = var.existing_intercept_deployment_group_id
}


# -------------------------------------------------------------------------------------
#  If mirroring_mode = true, create mirroring deployment instead.
# -------------------------------------------------------------------------------------

// Create an mirroring deployment for each zone within var.region
resource "google_network_security_mirroring_deployment" "main" {
  provider                   = google-beta
  for_each                   = var.mirroring_mode ? google_compute_forwarding_rule.main : {}
  mirroring_deployment_id    = "panw-deployment-${each.key}"
  location                   = each.key
  forwarding_rule            = each.value.id
  mirroring_deployment_group = var.existing_mirroring_deployment_group_id
}
