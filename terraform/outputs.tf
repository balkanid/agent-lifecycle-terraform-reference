output "gate_completed" {
  value = var.run_balkanid_gate ? null_resource.balkanid_gate[0].id : "skipped"
}
