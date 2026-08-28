resource "aws_vpc" "demo" {
  cidr_block                       = local.vpc_cidr
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = false

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "demo" {
  vpc_id = aws_vpc.demo.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public_app" {
  vpc_id                  = aws_vpc.demo.id
  cidr_block              = local.subnet_cidrs.public_app
  availability_zone       = var.availability_zones.public_app
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-public-app"
    Tier = "public-app"
  }
}

resource "aws_subnet" "private_db" {
  for_each = {
    a = {
      availability_zone = var.availability_zones.private_db_a
      cidr_block        = local.subnet_cidrs.private_db_a
    }
    b = {
      availability_zone = var.availability_zones.private_db_b
      cidr_block        = local.subnet_cidrs.private_db_b
    }
  }

  vpc_id                  = aws_vpc.demo.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-db-${each.key}"
    Tier = "private-db"
  }
}

resource "aws_route_table" "public_app" {
  vpc_id = aws_vpc.demo.id

  tags = {
    Name = "${local.name_prefix}-public-app"
  }
}

resource "aws_route" "public_app_ipv4" {
  route_table_id         = aws_route_table.public_app.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.demo.id
}

resource "aws_route_table_association" "public_app" {
  subnet_id      = aws_subnet.public_app.id
  route_table_id = aws_route_table.public_app.id
}

resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.demo.id

  tags = {
    Name = "${local.name_prefix}-private-db"
  }
}

resource "aws_route_table_association" "private_db" {
  for_each = aws_subnet.private_db

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_db.id
}
