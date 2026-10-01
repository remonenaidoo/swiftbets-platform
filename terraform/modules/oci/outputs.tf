output "public_ip" {
  description = "Public IP of the k3s node; also the egress IP Azure SQL must allow."
  value       = oci_core_instance.node.public_ip
}

output "kubeconfig_hint" {
  description = "How to fetch a kubeconfig once cloud-init has finished."
  value       = "ssh ubuntu@${oci_core_instance.node.public_ip} sudo cat /etc/rancher/k3s/k3s.yaml | sed 's/127.0.0.1/${oci_core_instance.node.public_ip}/' > kubeconfig-swiftbets"
}
