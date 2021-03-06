module VmRedhat::Operations::Guest
  def validate_shutdown_guest
    validate_vm_control_powered_on
  end

  def raw_shutdown_guest
    with_provider_object { |rhevm_vm| rhevm_vm.shutdown }
  rescue RhevmApiVmIsNotRunning
  end
end
