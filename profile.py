""" Ubuntu 20.04 Optional Kubernetes Cluster w/ OpenWhisk optionally deployed with a parameterized
number of nodes.
"""

import time
import geni.portal as portal
import geni.rspec.pg as rspec

BASE_IP = "10.10.1"
BANDWIDTH = 10000000
IMAGE = 'urn:publicid:IDN+utah.cloudlab.us+image+cu-bison-lab-PG0:openwhiskv3:4'

pc = portal.Context()

# --- Parameters ---
pc.defineParameter("nodeCount", 
                   "Number of nodes (Recommend 3+)",
                   portal.ParameterType.INTEGER, 
                   3)
pc.defineParameter("nodeType", 
                   "Node Hardware Type",
                   portal.ParameterType.NODETYPE, 
                   "m510",
                   longDescription="M510 or xl170 recommended.")
pc.defineParameter("startKubernetes",
                   "Create Kubernetes cluster",
                   portal.ParameterType.BOOLEAN,
                   True)
pc.defineParameter("deployOpenWhisk",
                   "Deploy OpenWhisk",
                   portal.ParameterType.BOOLEAN,
                   True)
pc.defineParameter("numInvokers",
                   "Number of Invokers",
                   portal.ParameterType.INTEGER,
                   1)
pc.defineParameter("invokerEngine",
                   "Invoker Engine",
                   portal.ParameterType.STRING,
                   "kubernetes",
                   legalValues=[('kubernetes', 'Kubernetes Container Engine'), ('docker', 'Docker Container Engine')])
pc.defineParameter("schedulerEnabled",
                   "Enable OpenWhisk Scheduler",
                   portal.ParameterType.BOOLEAN,
                   False)
pc.defineParameter("tempFileSystemSize", 
                   "Temporary Filesystem Size",
                   portal.ParameterType.INTEGER, 
                   0,
                   advanced=True,
                   longDescription="Size in GB. 0 indicates maximum size.")

params = pc.bindParameters()

if not params.startKubernetes and params.deployOpenWhisk:
    perr = portal.ParameterWarning("A Kubernetes cluster must be created in order to deploy OpenWhisk",['startKubernetes'])
    pc.reportError(perr)

pc.verifyParameters()
request = pc.makeRequestRSpec()

def create_node(name, nodes, lan):
  node = request.RawPC(name)
  node.disk_image = IMAGE
  node.hardware_type = params.nodeType
  
  iface = node.addInterface("if1")
  iface.addAddress(rspec.IPv4Address("{}.{}".format(BASE_IP, 1 + len(nodes)), "255.255.255.0"))
  lan.addInterface(iface)
  
  bs = node.Blockstore(name + "-bs", "/mydata")
  bs.size = str(params.tempFileSystemSize) + "GB"
  bs.placement = "any"
  
  nodes.append(node)

nodes = []
lan = request.LAN()
lan.bandwidth = BANDWIDTH

# Create nodes (10.10.1.1 is primary, .2+ are secondary)
for i in range(params.nodeCount):
    name = "ow"+str(i+1)
    create_node(name, nodes, lan)

# Iterate over secondary nodes first
for i, node in enumerate(nodes[1:]):
    node.addService(rspec.Execute(shell="bash", command="/local/repository/start.sh secondary {}.{} {} > /home/cloudlab-openwhisk/start.log 2>&1 &".format(
      BASE_IP, i + 2, params.startKubernetes)))

# Start primary node
nodes[0].addService(rspec.Execute(shell="bash", command="/local/repository/start.sh primary {}.1 {} {} {} {} {} {} > /home/cloudlab-openwhisk/start.log 2>&1".format(
  BASE_IP, params.nodeCount, params.startKubernetes, params.deployOpenWhisk, params.numInvokers, params.invokerEngine, params.schedulerEnabled)))

pc.printRequestRSpec()