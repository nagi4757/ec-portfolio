data "aws_ssm_parameter" "al2023_x86_64_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "demo" {
  ami                         = data.aws_ssm_parameter.al2023_x86_64_ami.value
  instance_type               = "t3a.medium"
  subnet_id                   = aws_subnet.public_app.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.ec2_origin.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name

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
