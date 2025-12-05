# main.tf
terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.89.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "yandex" {
  token     = var.yc_token
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = var.yc_zone
}

# Используем существующую сеть вместо создания новой
data "yandex_vpc_network" "network" {
  name = "default"
}

# Создаем подсеть в существующей сети
resource "yandex_vpc_subnet" "public_subnet" {
  name           = "public-subnet-sokolkov"
  zone           = var.yc_zone
  network_id     = data.yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.100.0/24"]  # Изменили на другой диапазон
}

# 2. Создаем сервисный аккаунт для бакета
resource "yandex_iam_service_account" "sa" {
  name        = "sa-sokolkov-153"
  description = "Service account for bucket and instance group"
}

resource "yandex_resourcemanager_folder_iam_member" "sa-editor" {
  folder_id = var.yc_folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa-key" {
  service_account_id = yandex_iam_service_account.sa.id
  description        = "Static access key for bucket"
}

# 1. Создаем ключ KMS 
resource "yandex_kms_symmetric_key" "bucket-key" {
  name              = "sokolkov-bucket-key"
  description       = "KMS key for bucket encryption"
  default_algorithm = "AES_256"
  rotation_period   = "8760h" # на год
}

# права добавляем для сервисного аккаунта
resource "yandex_resourcemanager_folder_iam_member" "kms-user" {
  folder_id = var.yc_folder_id
  role      = "kms.keys.encrypterDecrypter"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

# 3. Создаем бакет и загружаем картинку
# бакет с шифрованием и настройками для статического сайта
resource "yandex_storage_bucket" "bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-key.secret_key
  bucket     = "sokolkov-153"
  
  anonymous_access_flags {
    read = true
    list = false
  }

  # Настройки для статического сайта
  website {
    index_document = "index.html"
    error_document = "error.html"
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = yandex_kms_symmetric_key.bucket-key.id
        sse_algorithm     = "aws:kms"
      }
    }
  }

  depends_on = [
    yandex_kms_symmetric_key.bucket-key,
    yandex_resourcemanager_folder_iam_member.kms-user
  ]
}

resource "yandex_storage_object" "image" {
  bucket      = yandex_storage_bucket.bucket.bucket
  access_key  = yandex_iam_service_account_static_access_key.sa-key.access_key
  secret_key  = yandex_iam_service_account_static_access_key.sa-key.secret_key
  key         = "sokolkov.jpg"
  source      = "./sokolkov.jpg"
  acl         = "public-read"
}

# Создаем index.html для статического сайта
resource "yandex_storage_object" "index_html" {
  bucket      = yandex_storage_bucket.bucket.bucket
  access_key  = yandex_iam_service_account_static_access_key.sa-key.access_key
  secret_key  = yandex_iam_service_account_static_access_key.sa-key.secret_key
  key         = "index.html"
  content     = <<-EOF
    <!DOCTYPE html>
    <html>
    <head>
        <title>Sokolkov Static Site</title>
        <meta charset="UTF-8">
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; }
            h1 { color: #333; }
            img { max-width: 600px; border-radius: 10px; box-shadow: 0 4px 8px rgba(0,0,0,0.1); }
            .container { text-align: center; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Домашнее задание 15.3 - Sokolkov</h1>
            <h2>Статический сайт с шифрованием</h2>
            <img src="sokolkov.jpg" alt="Sokolkov Image">
            <p>Бакет зашифрован с помощью KMS ключа</p>
            <p>Время: <span id="datetime"></span></p>
        </div>
        <script>
            document.getElementById('datetime').textContent = new Date().toLocaleString();
        </script>
    </body>
    </html>
  EOF
  content_type = "text/html"
  acl         = "public-read"
}

# 4. Создаем группу ВМ с LAMP
data "yandex_compute_image" "lamp" {
  family = "lamp"
}

resource "yandex_compute_instance_group" "lamp-group" {
  name                = "lamp-group-sokolkov"
  folder_id           = var.yc_folder_id
  service_account_id  = yandex_iam_service_account.sa.id
  deletion_protection = false

  instance_template {
    platform_id = "standard-v3"
    resources {
      memory = 2
      cores  = 2
    }

    boot_disk {
      initialize_params {
        image_id = data.yandex_compute_image.lamp.id
        size     = 10
      }
    }

    network_interface {
      subnet_ids = [yandex_vpc_subnet.public_subnet.id]
      nat       = true
    }

    metadata = {
      ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
      user-data = <<-EOF
        #cloud-config
        runcmd:
          - cd /var/www/html
          - echo '<html><h1>Sokolkov 153</h1><img src="http://${yandex_storage_bucket.bucket.bucket_domain_name}/sokolkov.jpg"/></html>' | sudo tee index.html
          - sudo systemctl restart apache2
      EOF
    }
  }

  scale_policy {
    fixed_scale {
      size = 2  # Уменьшили с 3 до 2 из экономии
    }
  }

  allocation_policy {
    zones = [var.yc_zone]
  }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
  }

  load_balancer {
    target_group_name        = "lamp-target-group"
    target_group_description = "Target group for LAMP instances"
  }

  health_check {
    interval = 2
    timeout  = 1
    tcp_options {
      port = 80
    }
  }
}

# 5. Создаем Network Load Balancer (убираем, чтобы сэкономить ресурсы)
# resource "yandex_lb_network_load_balancer" "nlb" {
#   name = "nlb-sokolkov-153"

#   listener {
#     name = "http-listener"
#     port = 80
#     external_address_spec {
#       ip_version = "ipv4"
#     }
#   }

#   attached_target_group {
#     target_group_id = yandex_compute_instance_group.lamp-group.load_balancer[0].target_group_id

#     healthcheck {
#       name = "http"
#       http_options {
#         port = 80
#         path = "/"
#       }
#     }
#   }
# }

# 6. Создаем Application Load Balancer (убираем, чтобы сэкономить ресурсы)
# resource "yandex_vpc_address" "alb-address" {
#   name = "alb-address-sokolkov"
#   external_ipv4_address {
#     zone_id = var.yc_zone
#   }
# }

# resource "yandex_alb_target_group" "lamp-target-group" {
#   name = "lamp-target-group-sokolkov"
  
#   target {
#     subnet_id   = yandex_vpc_subnet.public_subnet.id
#     ip_address  = yandex_compute_instance_group.lamp-group.instances[0].network_interface[0].ip_address
#   }
  
#   target {
#     subnet_id   = yandex_vpc_subnet.public_subnet.id
#     ip_address  = yandex_compute_instance_group.lamp-group.instances[1].network_interface[0].ip_address
#   }
# }

# resource "yandex_alb_backend_group" "lamp-backend-group" {
#   name = "lamp-backend-group-sokolkov"

#   http_backend {
#     name             = "lamp-http-backend"
#     weight           = 1
#     port             = 80
#     target_group_ids = [yandex_alb_target_group.lamp-target-group.id]
#     healthcheck {
#       timeout          = "1s"
#       interval         = "2s"
#       http_healthcheck {
#         path = "/"
#       }
#     }
#   }
# }

# resource "yandex_alb_http_router" "lamp-router" {
#   name = "lamp-router-sokolkov"
# }

# resource "yandex_alb_virtual_host" "lamp-host" {
#   name           = "lamp-host-sokolkov"
#   http_router_id = yandex_alb_http_router.lamp-router.id
#   route {
#     name = "lamp-route"
#     http_route {
#       http_route_action {
#         backend_group_id = yandex_alb_backend_group.lamp-backend-group.id
#       }
#     }
#   }
# }

# resource "yandex_alb_load_balancer" "alb" {
#   name               = "alb-sokolkov-153"
#   network_id         = data.yandex_vpc_network.network.id

#   allocation_policy {
#     location {
#       zone_id   = var.yc_zone
#       subnet_id = yandex_vpc_subnet.public_subnet.id
#     }
#   }

#   listener {
#     name = "http-listener"
#     endpoint {
#       address {
#         external_ipv4_address {
#           address = yandex_vpc_address.alb-address.external_ipv4_address[0].address
#         }
#       }
#       ports = [80]
#     }
#     http {
#       handler {
#         http_router_id = yandex_alb_http_router.lamp-router.id
#       }
#     }
#   }

#   depends_on = [
#     yandex_alb_backend_group.lamp-backend-group,
#     yandex_alb_target_group.lamp-target-group
#   ]
# }

# Outputs
output "bucket_url" {
  value = "http://${yandex_storage_bucket.bucket.bucket_domain_name}/sokolkov.jpg"
}

output "static_site_url" {
  value = "http://${yandex_storage_bucket.bucket.bucket}.website.yandexcloud.net"
}

# output "nlb_public_ip" {
#   value = one([
#     for listener in yandex_lb_network_load_balancer.nlb.listener : 
#     one(listener.external_address_spec[*].address)
#   ])
# }

# output "alb_public_ip" {
#   value = yandex_vpc_address.alb-address.external_ipv4_address[0].address
# }

output "kms_key_id" {
  value = yandex_kms_symmetric_key.bucket-key.id
}

output "bucket_encryption_status" {
  value = yandex_storage_bucket.bucket.server_side_encryption_configuration
}

output "vm_public_ips" {
  value = yandex_compute_instance_group.lamp-group.instances[*].network_interface[0].nat_ip_address
}
