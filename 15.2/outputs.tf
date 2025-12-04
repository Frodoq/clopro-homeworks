output "instance_ips" {
  value = yandex_compute_instance_group.group.instances[*].network_interface[0].ip_address
}

output "load_balancer_info" {
  value = "Network Load Balancer создан. Проверьте его IP в консоли Yandex Cloud"
}
