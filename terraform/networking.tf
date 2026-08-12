# Control 3 — Network: deny-by-default VPC + security group

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "agent" {
  # Control 3: isolated VPC for the ephemeral agent
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "agent" {
  # Control 3: IGW for the public subnet (NAT egress path only)
  vpc_id = aws_vpc.agent.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  # Control 3: public subnet hosts the NAT Gateway only
  vpc_id                  = aws_vpc.agent.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-public"
  }
}

resource "aws_subnet" "private" {
  # Control 3: private subnet — ECS Fargate task runs here (no inbound path)
  vpc_id            = aws_vpc.agent.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private"
  }
}

resource "aws_eip" "nat" {
  # Control 3: Elastic IP for the NAT Gateway (outbound-only internet)
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }

  depends_on = [aws_internet_gateway.agent]
}

resource "aws_nat_gateway" "agent" {
  # Control 3: private subnet gets outbound-only internet via NAT (no inbound route)
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${var.project_name}-nat"
  }

  depends_on = [aws_internet_gateway.agent]
}

resource "aws_route_table" "public" {
  # Control 3: public route table — IGW for NAT Gateway connectivity
  vpc_id = aws_vpc.agent.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.agent.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  # Control 3: private route table — default route via NAT only (outbound)
  vpc_id = aws_vpc.agent.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.agent.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Control 3: security group — zero inbound; exactly one egress rule (443/tcp).
#
# Known, accepted limitation: this restricts by port only, not by destination
# domain. True domain-level allowlisting (e.g. only api.github.com and the LLM
# API domain) would require AWS Network Firewall, which has an hourly cost not
# justified for a documentation-scope project. Do not add Network Firewall or a
# proxy here — port-only egress is the intentional trade-off.
resource "aws_security_group" "agent" {
  name        = "${var.project_name}-agent-sg"
  description = "Deny-by-default SG for AI agent task: no ingress, egress 443 only"
  vpc_id      = aws_vpc.agent.id

  egress {
    description = "HTTPS outbound only (port allowlist; not domain allowlist)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-agent-sg"
  }
}

resource "aws_vpc_endpoint" "s3" {
  # Control 3: free S3 Gateway endpoint so audit-bucket traffic stays off the NAT/public internet
  # Prefer Gateway (no hourly charge) over Interface Endpoint.
  vpc_id            = aws_vpc.agent.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.project_name}-s3-gateway"
  }
}
