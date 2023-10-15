terraform {
  required_version = ">=1.0"
  
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Create a resource group
resource "azurerm_resource_group" "vmweb" {
 name     = var.resource_group_name
 location = var.location
 tags     = var.tags
}

# Random String Helper
resource "random_string" "fqdn" {
 length  = 6
 special = false
 upper   = false
 number  = false
}

# Create virtual network
resource "azurerm_virtual_network" "vmweb" {
 name                = "vmweb-vnet"
 address_space       = ["10.0.0.0/16"]
 location            = var.location
 resource_group_name = azurerm_resource_group.vmweb.name
 tags                = var.tags
}

# Create a subnet
resource "azurerm_subnet" "vmweb" {
 name                 = "vmweb-subnet"
 resource_group_name  = azurerm_resource_group.vmweb.name
 virtual_network_name = azurerm_virtual_network.vmweb.name
 address_prefixes       = ["10.0.2.0/24"]
}

# Create a public IP address
resource "azurerm_public_ip" "vmweb" {
 name                         = "vmweb-public-ip"
 sku                          = "Standard"
 location                     = var.location
 resource_group_name          = azurerm_resource_group.vmweb.name
 allocation_method            = "Static"
 domain_name_label            = random_string.fqdn.result
 tags                         = var.tags
}

# Create a load balancer
resource "azurerm_lb" "vmweb" {
 name                = "vmweb-lb"
 location            = var.location
 resource_group_name = azurerm_resource_group.vmweb.name
 sku                 = "Standard"

 frontend_ip_configuration {
   name                 = "PublicIPAddress"
   public_ip_address_id = azurerm_public_ip.vmweb.id
 }

 tags = var.tags
}

# Create a backend pool
resource "azurerm_lb_backend_address_pool" "bpepool" {
 loadbalancer_id     = azurerm_lb.vmweb.id
 name                = "web-backend-pool"
}

# Create a health probe
resource "azurerm_lb_probe" "vmweb" {
 loadbalancer_id     = azurerm_lb.vmweb.id
 name                = "ssh-running-probe"
 port                = var.nginx_port
}

# Create a network security group
resource "azurerm_network_security_group" "vmweb" {
  name                = "vmweb-nsg"
  location            = azurerm_resource_group.vmweb.location
  resource_group_name = azurerm_resource_group.vmweb.name
}


# Create a rule to allow HTTP traffic
resource "azurerm_network_security_rule" "web-in" {
  name                        = "web-http-rule"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80","8080", "443"]
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.vmweb.name
  network_security_group_name = azurerm_network_security_group.vmweb.name
}

# Associate NSG TO Subnet
resource "azurerm_subnet_network_security_group_association" "nsgassociate" {
  subnet_id                 = azurerm_subnet.vmweb.id
  network_security_group_id = azurerm_network_security_group.vmweb.id
}


# Create a LoadBalancer Rule
resource "azurerm_lb_rule" "lbrule" {
   loadbalancer_id                = azurerm_lb.vmweb.id
   name                           = "http"
   protocol                       = "Tcp"
   frontend_port                  = var.application_port
   backend_port                   = var.nginx_port
   frontend_ip_configuration_name = "PublicIPAddress"
   probe_id                       = azurerm_lb_probe.vmweb.id
   backend_address_pool_ids       = [azurerm_lb_backend_address_pool.bpepool.id]
}

# Create a Linux VMSS
resource "azurerm_virtual_machine_scale_set" "vmweb" {
 name                = "vmweb-vmss"
 location            = var.location
 resource_group_name = azurerm_resource_group.vmweb.name
 upgrade_policy_mode = "Manual"

 sku {
   name     = "Standard_DS1_v2"
   tier     = "Standard"
   capacity = 1
 }

 storage_profile_image_reference {
   publisher = "Canonical"
   offer     = "UbuntuServer"
   sku       = "16.04-LTS"
   version   = "latest"
 }

 storage_profile_os_disk {
   name              = ""
   caching           = "ReadWrite"
   create_option     = "FromImage"
   managed_disk_type = "Standard_LRS"
 }

 storage_profile_data_disk {
   lun          = 0
   caching        = "ReadWrite"
   create_option  = "Empty"
   disk_size_gb   = 10
 }

 os_profile {
   computer_name_prefix = "vmlab"
   admin_username       = var.admin_user
   admin_password       = var.admin_password
   custom_data          = file("web.conf")
 }

 os_profile_linux_config {
   disable_password_authentication = false
 }

 network_profile {
   name    = "terraformnetworkprofile"
   primary = true

   ip_configuration {
     name                                   = "IPConfiguration"
     subnet_id                              = azurerm_subnet.vmweb.id
     load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.bpepool.id]
     primary = true
   }
 }

 tags = var.tags
}
