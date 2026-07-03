# NSI Multi-Regions Deployment Guide

This folder contains the Terraform configuration to deploy Palo Alto Networks VM-Series Firewalls under the Google Cloud Network Security Integration (NSI) framework in **additional regions** (secondary regions).

Instead of creating new VPCs or duplicating GCS bootstrap buckets, this multi-region module is designed to connect to your **existing VPC networks** and reuse the **GCS bootstrap bucket** created by the primary region module (`/producer`).

---

## Architecture

The multi-region setup connects additional zonal or regional VM-Series firewall deployments to the same central infrastructure:
1. **Existing VPCs**: Utilizes the existing management (`mgmt`) and dataplane (`data`) VPCs.
2. **Shared Bootstrapping**: Reuses the bootstrap GCS bucket created in the primary region, avoiding resource duplication.
3. **Zonal Deployments**: Creates subnetworks, regional managed instance groups (MIGs), regional internal load balancers, and hooks them to the existing global intercept or mirroring deployment group.

---

## Deployment Steps

### 1. Retrieve Primary Outputs
Deploy the primary region module in the `/producer` folder first. Upon completion, copy the outputs:
- **`BOOTSTRAP_BUCKET`**: The name of the bootstrap GCS bucket.
- **`DEPLOYMENT_GROUP`**: The ID/URI of the global deployment group (intercept or mirroring).

### 2. Configure Variables
Copy the example variable file to create your local variables:
```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set the following parameters:

| Parameter | Description |
| :--- | :--- |
| `project_id` | GCP Project ID. |
| `region` | The secondary region you are deploying resources into (e.g. `us-central1`). |
| `mgmt_network_name` | Name of the existing management VPC network created in the primary deployment. |
| `data_network_name` | Name of the existing dataplane VPC network created in the primary deployment. |
| `bootstrap_bucket` | The GCS bootstrap bucket name retrieved from the primary module's output (`BOOTSTRAP_BUCKET`). |
| `existing_mirroring_deployment_group_id` | (For Mirror Mode) The deployment group ID/URI retrieved from the primary module's output (`DEPLOYMENT_GROUP`). |
| `existing_intercept_deployment_group_id` | (For Intercept Mode) The deployment group ID/URI retrieved from the primary module's output (`DEPLOYMENT_GROUP`). |
| `subnet_cidr_mgmt` | Unique CIDR block for the management subnet in the secondary region. |
| `subnet_cidr_data` | Unique CIDR block for the dataplane subnet in the secondary region. |

### 3. Deploy
Initialize and apply the Terraform plan in this folder:
```bash
terraform init
terraform apply
```

This will automatically configure the subnetworks, Cloud NAT, MIG, and load balancers in the secondary region, and register the new zonal deployments to the existing deployment group.

### 4. Configure the NGFW
Once the Terraform deployment has completed in the secondary region, you must manually perform some post-deployment configuration inside the new region's NGFW (VM-Series Firewall) management console to make the internal Load Balancer (iLB) health check work correctly:

1. **Access the NGFW Console**:
   - If `mgmt_public_ip` is set to `true`, find the public IP of the newly deployed NGFW instance in your GCP Console.
   - If `mgmt_public_ip` is set to `false`, use the bastion host to tunnel through IAP and access the NGFW management console on your local port (e.g. via `gcloud compute ssh`).
2. **Log in to the Web Console**:
   - Access the web interface via HTTPS (e.g. `https://<NGFW_IP>` or `https://127.0.0.1:8081`).
   - Log in using the same credentials as the main region NGFW:
     - **Username**: `admin`
     - **Password**: `PaloAlto@123`
3. **Update Address Objects for the New Region Subnet**:
   - Navigate to **Objects** -> **Addresses** in the NGFW web interface.
   - Locate the address objects representing forwarding rules (typically named `gcp-lb-fwd-rule-1` to `gcp-lb-fwd-rule-6`).
   - Update their IP addresses to match the IP addresses assigned under the new region's dataplane subnet (e.g., changing from `10.0.1.200/32` to `11.0.1.200/32` or the respective IPs within your `subnet_cidr_data` IP range).
   - This step is critical to ensure that the internal Load Balancer (iLB) health checks succeed in the new region.
4. **Commit the Changes**:
   - Click **Commit** in the top-right corner to apply the changes to the firewall configuration.

### 5. Destroy

* ***Run `terraform destroy` from the `/producer/multi-regions` directory.***

    ```
    cd
    cd google-cloud-nsi-security-lifecycle/producer/multi-regions
    terraform destroy
    ```

* ***Enter `yes` to delete all producer resources.***