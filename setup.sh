#!/bin/bash

# Bağımlılıkları kontrol et ve yükle
check_dependencies() {
  dependencies=(dialog wimlib grub parted mkfs efibootmgr)
  for package in "${dependencies[@]}"; do
    if ! command -v $package &> /dev/null; then
      echo "$package yüklenmedi. Yükleniyor..."
      sudo pacman -S --noconfirm $package
    fi
  done
}

# Sudo kontrolü
if [ "$EUID" -ne 0 ]; then
  dialog --title "Sudo Yetkisi Gerekli" --msgbox "Lütfen bu aracı sudo ile çalıştırın." 10 60
  exit 1
fi

# Bağımlılık kontrolü ve yükleme
dialog --infobox "Bağımlılıklar kontrol ediliyor ve yükleniyor..." 5 60
check_dependencies
sleep 2

# Sistem modunu kontrol et (UEFI/Legacy)
is_uefi=$(ls /sys/firmware/efi/efivars &> /dev/null && echo "UEFI" || echo "Legacy")

# Sanal veya fiziksel ortam kontrolü
vm_check=$(sudo dmidecode -s system-manufacturer | grep -E "VMware|VirtualBox" && echo "Sanal" || echo "Fiziksel")

# Kullanıcıya bilgi verme
dialog --title "Windows Kurulum Aracı" --msgbox "Sistem: $is_uefi modunda ve $vm_check ortamda çalışıyor." 10 60

# EULA Sözleşmesi
dialog --title "EULA Sözleşmesi" --yesno "Windows EULA sözleşmesini kabul ediyor musunuz?" 10 60
if [ $? -ne 0 ]; then
  dialog --title "Kurulum İptal Edildi" --msgbox "EULA kabul edilmedi. Kurulum iptal edildi." 10 60
  exit 1
fi

# install.esd Dosyası Seçimi
esd_path=$(dialog --stdout --title "install.esd Dosya Yolu" --fselect / 14 48)
if [ -z "$esd_path" ]; then
  dialog --title "Hata" --msgbox "install.esd dosyası seçilmedi. Kurulum iptal edildi." 10 60
  exit 1
fi

# Disk Seçimi ve Listesi
disks=$(lsblk -dno NAME,SIZE,TYPE | grep -E "disk" | awk '{print "/dev/"$1" ("$2")"}')
disk=$(dialog --stdout --title "Disk Seçimi" --menu "Kurulumu yapmak istediğiniz diski seçin:" 15 50 5 $(echo "$disks" | tr '\n' ' '))
if [ -z "$disk" ]; then
  dialog --title "Hata" --msgbox "Bir disk seçilmedi. Kurulum iptal edildi." 10 60
  exit 1
fi

# Disk Onayı
dialog --title "Disk Onayı" --yesno "$disk üzerinde işlem yapılacak. Tüm veriler silinecek. Onaylıyor musunuz?" 10 60
if [ $? -ne 0 ]; then
  dialog --title "Kurulum İptal Edildi" --msgbox "Kurulum iptal edildi." 10 60
  exit 1
fi

# Bölümleme ve Biçimlendirme
if [ "$is_uefi" == "UEFI" ]; then
  (
    echo 20; sleep 1
    echo "# GPT olarak bölümleme yapılıyor..."
    parted $disk mklabel gpt
    parted $disk mkpart primary fat32 1MiB 500MiB
    parted $disk set 1 esp on
    parted $disk mkpart primary ntfs 500MiB 100%
    echo 40; sleep 1

    mkfs.fat -F32 "${disk}1"
    mkfs.ntfs -f "${disk}2"
    echo 60; sleep 1
  ) | dialog --gauge "UEFI için GPT ile biçimlendiriliyor..." 10 70 0
else
  (
    echo 20; sleep 1
    echo "# MBR olarak bölümleme yapılıyor..."
    parted $disk mklabel msdos
    parted $disk mkpart primary ntfs 1MiB 100%
    echo 60; sleep 1

    mkfs.ntfs -f "${disk}1"
    echo 80; sleep 1
  ) | dialog --gauge "Legacy için MBR ile biçimlendiriliyor..." 10 70 0
fi

# Bölümleri Bağlama
mount "${disk}2" /mnt
if [ "$is_uefi" == "UEFI" ]; then
  mkdir -p /mnt/boot/efi
  mount "${disk}1" /mnt/boot/efi
fi

# Windows İmaj Dosyasını Çıkarma
dialog --infobox "Windows imaj dosyası çıkarılıyor..." 5 50
wimlib-imagex apply "$esd_path" 1 /mnt

# GRUB Kurulumu ve Yapılandırma
(
  echo 80; sleep 1
  echo "# GRUB kurulumu yapılıyor..."
  if [ "$is_uefi" == "UEFI" ]; then
    grub-install --target=x86_64-efi --efi-directory=/mnt/boot/efi --boot-directory=/mnt/boot --removable
  else
    grub-install --target=i386-pc --boot-directory=/mnt/boot "$disk"
  fi
  echo 90; sleep 1

  grub-mkconfig -o /mnt/boot/grub/grub.cfg
  echo 100; sleep 1
) | dialog --gauge "GRUB kurulumu tamamlanıyor..." 10 70 0

# GRUB Menü Yapılandırması
cat <<EOF >> /mnt/boot/grub/grub.cfg
menuentry "Windows 10" {
    insmod part_${is_uefi,,}
    insmod ntfs
    set root='(hd0,${is_uefi,,}2)'
    chainloader +1
}
EOF

# Temizlik ve Bitirme
umount /mnt/boot/efi
umount /mnt

dialog --title "Kurulum Tamamlandı" --msgbox "Windows kurulumu başarıyla tamamlandı! Sistemi yeniden başlatabilirsiniz." 10 60
