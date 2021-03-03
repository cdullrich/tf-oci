variable "tenancy_ocid" {
}

variable "user_ocid" {
}

variable "fingerprint" {
}

variable "private_key_path" {
}

variable "region" {
}

variable "compartment_ocid" {
}

variable "ssh_public_key" {
}

variable "ssh_private_key" {
}

variable "subnet_ocid" {    
}

# Defines the number of instances to deploy
variable "num_instances" {
  default = "3"
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

data "oci_identity_availability_domain" "ad" {
compartment_id = var.tenancy_ocid
ad_number      = 1
}

# Defines the number of volumes to create and attach to each instance
# NOTE: Changing this value after applying it could result in re-attaching existing volumes to different instances.
# This is a result of using 'count' variables to specify the volume and instance IDs for the volume attachment resource.
variable "num_iscsi_volumes_per_instance" {
  default = "1"
}

variable "num_paravirtualized_volumes_per_instance" {
  default = "2"
}

variable "instance_shape" {
  default = "VM.Standard.E2.1.Micro"
}

variable "instance_ocpus" {
  default = 1
}

variable "instance_shape_config_memory_in_gbs" {
  default = 1
}

variable "instance_image_ocid" {
  type = map(string)
  default = {
    # See https://docs.us-phoenix-1.oraclecloud.com/images/
    # Oracle-provided image "Centos 8"
    us-phoenix-1   = "ocid1.image.oc1.phx.aaaaaaaa2o6pedsahmakjfcrzy3yyh2ju4zuuusxzgwdnr7pozqeqb6fp3jq"
  }
}

variable "flex_instance_image_ocid" {
  type = map(string)
  default = {
    us-phoenix-1 = "ocid1.image.oc1.phx.aaaaaaaa6hooptnlbfwr5lwemqjbu3uqidntrlhnt45yihfj222zahe7p3wq"
  }
}

variable "db_size" {
  default = "40" # size in GBs
}

variable "tag_namespace_description" {
  default = "This is the CDU namespace"
}

variable "tag_namespace_name" {
  default = "CDU-namespace"
}

resource "oci_core_instance" "CDU_instance" {
  count               = var.num_instances
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "CDUInstance${count.index}"
  shape               = "VM.Standard.E2.1.Micro"

  shape_config {
    ocpus = "${var.instance_ocpus}"
    memory_in_gbs = "${var.instance_shape_config_memory_in_gbs}"
  }

  create_vnic_details {
    subnet_id        = var.subnet_ocid
    display_name     = "internalvnic"
    assign_public_ip = false
    hostname_label   = "CDUinstance${count.index}"
  }

  source_details {
    source_type = "image"
    source_id = var.flex_instance_image_ocid[var.region]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  freeform_tags = {
    "freeformkey${count.index}" = "freeformvalue${count.index}"
  }
  timeouts {
    create = "60m"
  }
}

# Define the volumes that are attached to the compute instances.

resource "oci_core_volume" "CDU_block_volume" {
  count               = var.num_instances * var.num_iscsi_volumes_per_instance
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "CDUBlock${count.index}"
  size_in_gbs         = "40"
}

resource "oci_core_volume_attachment" "CDU_block_attach" {
  count           = var.num_instances * var.num_iscsi_volumes_per_instance
  attachment_type = "iscsi"
  instance_id     = oci_core_instance.CDU_instance[floor(count.index / var.num_iscsi_volumes_per_instance)].id
  volume_id       = oci_core_volume.CDU_block_volume[count.index].id
  device          = count.index == 0 ? "/dev/oracleoci/oraclevdb" : ""
  use_chap = true
}

resource "null_resource" "remote-exec" {
  depends_on = [
    oci_core_instance.CDU_instance,
    oci_core_volume_attachment.CDU_block_attach,
  ]
  count = var.num_instances * var.num_iscsi_volumes_per_instance

  provisioner "remote-exec" {
    connection {
      agent       = false
      timeout     = "30m"
      host        = oci_core_instance.CDU_instance[count.index % var.num_instances].private_ip
      user        = "opc"
      private_key = var.ssh_private_key
    }

    inline = [
      "sudo iscsiadm -m node -o new -T ${oci_core_volume_attachment.CDU_block_attach[count.index].iqn} -p ${oci_core_volume_attachment.CDU_block_attach[count.index].ipv4}:${oci_core_volume_attachment.CDU_block_attach[count.index].port}",
      "sudo iscsiadm -m node -o update -T ${oci_core_volume_attachment.CDU_block_attach[count.index].iqn} -n node.startup -v automatic",
      "sudo iscsiadm -m node -T ${oci_core_volume_attachment.CDU_block_attach[count.index].iqn} -p ${oci_core_volume_attachment.CDU_block_attach[count.index].ipv4}:${oci_core_volume_attachment.CDU_block_attach[count.index].port} -l",
      "sudo yum update"
    ]
  }

  provisioner "file" {
    source      = "/home/vagrant/code/goci/goci"
    destination = "/tmp/goci"
  }

  provisioner "remote-exec" {
    connection {
      agent       = false
      timeout     = "30m"
      host        = oci_core_instance.CDU_instance[count.index % var.num_instances].private_ip
      user        = "opc"
      private_key = var.ssh_private_key
    }

    inline = [
      "./goci"
    ]      
  }
}

# Gets the boot volume attachments for each instance
data "oci_core_boot_volume_attachments" "CDU_boot_volume_attachments" {
  depends_on          = [oci_core_instance.CDU_instance]
  count               = var.num_instances
  availability_domain = oci_core_instance.CDU_instance[count.index].availability_domain
  compartment_id      = var.compartment_ocid

  instance_id = oci_core_instance.CDU_instance[count.index].id
}

data "oci_core_instance_devices" "CDU_instance_devices" {
  count       = var.num_instances
  instance_id = oci_core_instance.CDU_instance[count.index].id
}

# Output the private and public IPs of the instance

output "instance_private_ips" {
  value = [oci_core_instance.CDU_instance.*.private_ip]
}

# Output the boot volume IDs of the instance
output "boot_volume_ids" {
  value = [oci_core_instance.CDU_instance.*.boot_volume_id]
}

# Output all the devices for all instances
output "instance_devices" {
  value = [data.oci_core_instance_devices.CDU_instance_devices.*.devices]
}

output "attachment_instance_id" {
  value = data.oci_core_boot_volume_attachments.CDU_boot_volume_attachments.*.instance_id
}