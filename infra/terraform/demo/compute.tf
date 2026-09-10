resource "aws_instance" "demo" {
  ami                    = local.demo_ami_id
  instance_type          = "t3a.medium"
  subnet_id              = aws_subnet.public_app.id
  vpc_security_group_ids = [aws_security_group.ec2_origin.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  depends_on = [aws_iam_role_policy.ec2_session_manager]

  # This host carries state Terraform does not rebuild: the runtime scripts
  # under /opt/ec-portfolio/runtime/demo/, the origin TLS certificate, the
  # certbot systemd units and the Docker images, containers and network. A
  # replacement silently discards all of it, so any change that would force one
  # has to fail the plan instead.
  #
  # This is deliberately separate from pinning the AMI. The pin removes the one
  # cause we already hit; this guard covers the ones we have not. A planned
  # replacement is done by lifting this guard in its own reviewed PR, together
  # with the rebuild runbook in README.md.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name     = "${local.name_prefix}-ec2"
    AutoStop = "true"
  }
}

resource "aws_eip" "ec2_origin" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-ec2-origin"
  }
}

resource "aws_eip_association" "ec2_origin" {
  allocation_id = aws_eip.ec2_origin.id
  instance_id   = aws_instance.demo.id
}
