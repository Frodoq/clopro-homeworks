terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.96.0"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  zone      = "ru-central1-a"
  token     = var.token
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
}

variable "token" {
  description = "Yandex Cloud OAuth token or IAM token"
  type        = string
  sensitive   = true
}

variable "folder_id" {
  description = "Yandex Cloud Folder ID"
  type        = string
}

variable "cloud_id" {
  description = "Yandex Cloud ID"
  type        = string
}

# Используем существующую сеть default
data "yandex_vpc_network" "default" {
  network_id = "enpp0sq9km64rku9qfjn" # ID сети default
}

# Создание публичной подсети в зоне ru-central1-a
resource "yandex_vpc_subnet" "public" {
  name           = "public-ru-central1-a"
  zone           = "ru-central1-a"
  network_id     = data.yandex_vpc_network.default.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

# Создание таблицы маршрутизации для приватной сети
resource "yandex_vpc_route_table" "private-rt" {
  name       = "private-route-table"
  network_id = data.yandex_vpc_network.default.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    next_hop_address   = "192.168.10.254" # NAT-инстанс
  }
}

# Создание приватной подсети с привязкой к таблице маршрутизации
resource "yandex_vpc_subnet" "private" {
  name           = "private-ru-central1-a"
  zone           = "ru-central1-a"
  network_id     = data.yandex_vpc_network.default.id
  v4_cidr_blocks = ["192.168.20.0/24"]
  route_table_id = yandex_vpc_route_table.private-rt.id
}

# Создание сервисного аккаунта для инстансов
resource "yandex_iam_service_account" "sa" {
  name = "vm-service-account"
}

# Назначение роли сервисному аккаунту
resource "yandex_resourcemanager_folder_iam_member" "sa-editor" {
  folder_id = var.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

# Создание NAT-инстанса в публичной подсети
resource "yandex_compute_instance" "nat-instance" {
  name        = "nat-instance"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd80mrhj8fl2oe87o4e1" # Ubuntu 20.04 с предустановленным NAT
    }
  }

  network_interface {
    subnet_id   = yandex_vpc_subnet.public.id
    ip_address  = "192.168.10.254"
    nat         = true # Публичный IP для NAT-инстанса
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  service_account_id = yandex_iam_service_account.sa.id
}

# Создание виртуалки в публичной подсети
resource "yandex_compute_instance" "public-vm" {
  name        = "public-vm"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd80bm0rh4rkepi5ksdi" # Ubuntu 22.04 LTS
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.public.id
    nat       = true # Публичный IP
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  service_account_id = yandex_iam_service_account.sa.id
}

# Создание виртуалки в приватной подсети
resource "yandex_compute_instance" "private-vm" {
  name        = "private-vm"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd80bm0rh4rkepi5ksdi" # Ubuntu 22.04 LTS
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.private.id
    # Нет nat = true, только внутренний IP
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  service_account_id = yandex_iam_service_account.sa.id
}

output "nat_instance_ip" {
  value = yandex_compute_instance.nat-instance.network_interface.0.nat_ip_address
}

output "public_vm_ip" {
  value = yandex_compute_instance.public-vm.network_interface.0.nat_ip_address
}

output "private_vm_internal_ip" {
  value = yandex_compute_instance.private-vm.network_interface.0.ip_address
}
