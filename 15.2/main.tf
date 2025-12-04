terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.96.0"
    }
  }
}

provider "yandex" {
  token     = var.token
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
}

variable "token" {
  type      = string
  sensitive = true
}

variable "folder_id" {
  type = string
}

variable "cloud_id" {
  type = string
}

# 1. Сервисный аккаунт для Instance Group
resource "yandex_iam_service_account" "sa" {
  name        = "sa-15-2"
  description = "Service account for homework 15.2"
}

# Даем права сервисному аккаунту
resource "yandex_resourcemanager_folder_iam_member" "editor" {
  folder_id = var.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

# Роль vpc.user для использования сети
resource "yandex_resourcemanager_folder_iam_member" "vpc-user" {
  folder_id = var.folder_id
  role      = "vpc.user"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

# 2. Instance Group с 2 ВМ (для экономии)
resource "yandex_compute_instance_group" "group" {
  name                = "lamp-instance-group"
  folder_id           = var.folder_id
  service_account_id  = yandex_iam_service_account.sa.id
  deletion_protection = false

  instance_template {
    service_account_id = yandex_iam_service_account.sa.id
    platform_id        = "standard-v3"

    resources {
      cores  = 2
      memory = 2
    }

    boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = "fd827b91d99psvq5fjit" # LAMP image
        size     = 10
      }
    }

    network_interface {
      network_id = "enpp0sq9km64rku9qfjn"
      subnet_ids = ["e9bkvk040r4938ui1f7e"]
      nat        = true
    }

    metadata = {
      ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
      user-data = <<-EOT
        #cloud-config
        package_update: true
        packages:
          - apache2
        runcmd:
          - systemctl start apache2
          - echo '<html><h1>Netology Homework 15.2</h1><p>Instance created via Terraform</p><p>Instance Hostname: '`hostname`'</p><p>Load Balancer test page</p></html>' > /var/www/html/index.html
      EOT
    }
  }

  scale_policy {
    fixed_scale {
      size = 2
    }
  }

  allocation_policy {
    zones = ["ru-central1-a"]
  }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
  }

  # Health check
  health_check {
    interval            = 5
    timeout             = 1
    unhealthy_threshold = 5
    healthy_threshold   = 3

    http_options {
      port = 80
      path = "/"
    }
  }

  load_balancer {
    target_group_name = "lamp-target-group"
  }
}

# 3. Network Load Balancer
resource "yandex_lb_network_load_balancer" "nlb" {
  name = "lamp-network-lb"

  listener {
    name = "http-listener"
    port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.group.load_balancer.0.target_group_id

    healthcheck {
      name                = "http"
      interval            = 2
      timeout             = 1
      unhealthy_threshold = 5
      healthy_threshold   = 3
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}
