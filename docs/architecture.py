#!/usr/bin/env python3
"""
Architecture diagram for terraform-aws-sftp, built with official AWS icons.

Regenerate after changing the module's shape:

    python3 -m venv .venv && .venv/bin/pip install diagrams   # needs graphviz installed
    .venv/bin/python docs/architecture.py

Writes docs/architecture.png and docs/architecture.svg.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2ElasticIpAddress, EC2Instance
from diagrams.aws.general import Users
from diagrams.aws.management import CloudwatchLogs, SystemsManagerRunCommand
from diagrams.aws.network import PublicSubnet, VPC
from diagrams.aws.security import SecretsManager
from diagrams.aws.storage import SimpleStorageServiceS3Bucket

GRAPH_ATTR = {
    "fontname": "Helvetica",
    "fontsize": "11",
    "labelloc": "t",
    "pad": "0.6",
    "nodesep": "0.55",
    "ranksep": "1.0",
    "splines": "spline",
    "bgcolor": "white",
}

NODE_ATTR = {"fontname": "Helvetica", "fontsize": "10"}
EDGE_ATTR = {"fontname": "Helvetica", "fontsize": "9", "color": "#5A6B7B"}

CLUSTER = {
    "fontname": "Helvetica",
    "fontsize": "11",
    "style": "rounded,dashed",
    "penwidth": "1.6",
    "margin": "18",
}

with Diagram(
    "",
    filename="docs/architecture",
    outformat=["png", "svg"],
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
    node_attr=NODE_ATTR,
    edge_attr=EDGE_ATTR,
):
    client = Users("SFTP Client")
    admin = Users("Admin")

    eip = EC2ElasticIpAddress("Elastic IP\nfixed address")
    ssm = SystemsManagerRunCommand("SSM")

    with Cluster("VPC", graph_attr={**CLUSTER, "color": "#8C4FFF"}):
        with Cluster("Public subnet", graph_attr={**CLUSTER, "color": "#00A4A6"}):
            host = EC2Instance("EC2  t4g.medium")

    bucket = SimpleStorageServiceS3Bucket("S3")
    secrets = SecretsManager("Secrets Manager")
    logs = CloudwatchLogs("CloudWatch Logs")

    client >> Edge(label="  port 22", color="#334155", penwidth="1.6") >> eip
    eip >> Edge(color="#334155", penwidth="1.6") >> host

    host >> Edge(label="  files") >> bucket
    host >> Edge(label="  credentials") >> secrets
    host >> Edge(label="  logs") >> logs

    admin >> Edge(color="#8C4FFF", penwidth="1.6") >> ssm
    ssm >> Edge(color="#8C4FFF", penwidth="1.6") >> host

# ---------------------------------------------------------------------------
# graphviz writes the SVG with <image xlink:href="/abs/path/to/icon.png">, which
# points into the local site-packages install. Every icon would be a broken image
# anywhere else, so inline them as data URIs to make the SVG self-contained.
# ---------------------------------------------------------------------------
import base64
import pathlib
import re

svg_path = pathlib.Path("docs/architecture.svg")
svg = svg_path.read_text()


def _inline(match):
    src = pathlib.Path(match.group(1))
    if not src.is_file():
        raise SystemExit(f"icon missing, cannot inline: {src}")
    b64 = base64.b64encode(src.read_bytes()).decode()
    return f'xlink:href="data:image/png;base64,{b64}"'


svg, n = re.subn(r'xlink:href="(/[^"]+\.png)"', _inline, svg)
svg_path.write_text(svg)
print(f"inlined {n} icons into {svg_path}")
