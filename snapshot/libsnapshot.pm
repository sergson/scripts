#!/usr/bin/perl -w
# Библиотека функций работы со снапшотами.
# Author: Nevorotin Vadim aka Malamut
# Лицензия: GPLv3
 
use 5.010;
 
# Проверка элемента на вхождение в массив (а-ля оператор in)
sub isIn {
	@_ > 0 or die "isIn - OOPS!\n";
	my $element = shift @_;
	my @arr = @_;
	foreach (@arr) {
		if ($_ eq $element) { return 1 }
	}
	return 0;
}
 
# Возвращает текущее время в формате yyyy.mm.dd-hh.mm.ss
sub getDate {
	my @time = localtime;
	return ($time[5] + 1900) . '.' . sprintf("%02d",$time[4] + 1) . '.' . sprintf("%02d",$time[3]) . "-" .
		sprintf("%02d",$time[2]) . '.' . sprintf("%02d",$time[1]) . '.' . sprintf("%02d",$time[0]);
}
 
# Функция ищет все примонтированные снапшоты из заданной Volume Group в заданную директорию
sub getMounted {
	@_ == 2 or die "getMounted - OOPS!\n";
	my ($vg,$path) = @_;
 
	my @snapshots = ();
	foreach (`mount | grep /dev/mapper/$vg`) {
		if (/$vg-(\d{4}\.\d{2}\.\d{2})--(\d{2}\.\d{2}.\d{2})\s+\S+\s+$path\/\@GMT-\1-\2\s+/) {
			push @snapshots, "$1-$2";
		}
	}
	return @snapshots;
}
 
# Функция ищет все снапшоты для указанного тома из указанной VG. Возвращяет хеш снапшот-состояние
sub getActive {
	@_ == 2 or die "getActive - OOPS!\n";
	my ($lv,$vg) = @_;
 	
	my %snapshots = ();
	my $flag = 0;	
	foreach (`/usr/sbin/lvdisplay /dev/$vg/$lv 2>&1`) {
		if (/LV\ssnapshot\sstatus/) { $flag = 1 }
		elsif ($flag) {
			if (m#^\s+(\S+)\s+\[(\S+)]#) {
				$snapshots{$1} = lc $2;
			} else { $flag = 0 }		
		}
	}
	return %snapshots;
}
 
# Функция ищет все каталоги для снапшотов в заданной директории
sub getListed {
	@_ == 1 or die "getListed - OOPS!\n";
        my $path = shift @_;
 
	my @dirs = ();
	my @content = glob "$path/\@GMT*";
	foreach (@content) {
		if (-d $_ and /GMT-(\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}.\d{2})/) {
			push @dirs, $1;
		}
	}
	return @dirs;
}
 
# Создаёт снапшот с текущим временем для тома LV в группе VG и монтирует
# в подкаталог path с именем @GMT-sn_name 
sub createSnapshot {
	@_ == 4 or die "createSnapshot - OOPS!\n";
	my ($lv, $vg, $path, $sn_size) = @_;
 
	my $sn_name = getDate; 
 
	# Создаём директорию под снапшот
	mkdir "$path/\@GMT-$sn_name", 0777 or die "I can't create a directory for snapshot $sn_name! ($!)\n";
 
	# Создаём снапшот
	if (system "/usr/sbin/lvcreate -L ${sn_size}G -s -n $sn_name /dev/$vg/$lv 1>/dev/null") {
		rmdir "$path/\@GMT-$sn_name" or warn "Very big error: I can't remove a directory for snapshot :(";
		die "I can't create a snapshot $sn_name!\n";
	}
 
	# Монтируем
	if (system "mount -o ro,acl,user_xattr /dev/$vg/$sn_name $path/\@GMT-$sn_name") {
		!system "/usr/sbin/lvremove -f /dev/$vg/$sn_name 1>/dev/null" or warn "Very big error: I can't remove a snapshot :(";
		rmdir "$path/\@GMT-$sn_name" or warn "Very big error: I can't remove a directory for snapshot :(";
		die "I can't mount a new snapshot $sn_name to directory!";
	}
}
 
# Удаляет снапшот из группы томов VG с именем snName, а так же пытается удалить каталог для снапшота в директории
# с адресом path и если снапшот примонтирован, то и тот каталог, куда примонтирован
sub removeSnapshot {
	@_ == 3 or die "removeSnapshot - OOPS!\n";
	my ($sn_name, $vg, $path) = @_;

	# Проверяем смонтирован ли, и если да - то куда
	my $mpath = $path;
	chomp(my $ms = `mount | grep $sn_name`);
	if ($ms) {
		($mpath) = $ms =~ /^\S+\s+\S+\s+(\S+)/;
		!system "umount -lf /dev/$vg/$sn_name" or die "I can't umount $sn_name!\n";
		rmdir $mpath or die "I can't remove directory $mpath!\n";	
	}
	# Удаляем директорию для снапшота
	if (-e "$path/\@GMT-$sn_name") {
		rmdir "$path/\@GMT-$sn_name" or die "I can't remove directory $path/\@GMT-$sn_name!\n";	
	}
	# Удаляем снапшот
	!system "/usr/sbin/lvremove -f /dev/$vg/$sn_name 1>/dev/null 2>/dev/null" or die "I can't remove a snapshot $sn_name!\n";
}
 
# Проверяет размер снапшота и при необходимости и возможности увеличивает его
sub checkSize {
	@_ == 4 or die "checkSize - OOPS!\n";
	my ($sn_name, $vg, $sn_limit, $sn_add) = @_;
 
	my $size = 0;
	foreach (`/usr/sbin/lvdisplay /dev/$vg/$sn_name 2>&1`) {
		if (/Allocated\s+to\s+snapshot\s+(\S+)%/) { $size = $1	}	
	}
	if ( $size > $sn_limit ) {
		!system "/usr/sbin/lvextend -L +${sn_add}G /dev/$vg/$sn_name 1>/dev/null 2>/dev/null" or warn "I can't extend snapshot $sn_name!\n";
	}
}
 
# Функция ротации снапшотов. Для заданного тома LV в заданной VG пытается поддерживать ровно COUNT снапшотов.
# При вызове всегда создаёт новый снапшот, при этом если надо - удаляет самый старый.
# Проверяет также текущие снапшоты, удаляет INACTIVE и расширяет те, которым необходимо расширение.
# sn_limit - в процентах (0..100), sn_size и sn_add - в гигабайтах
# snapshotsRotate($lv, $vg, $path, $count, $sn_size, $sn_limit, $sn_add)
sub snapshotsRotate {
	@_ == 7 or die "snapshotsRotate - OOPS!\n";
	my ($lv, $vg, $path, $count, $sn_size, $sn_limit, $sn_add) = @_;
 
	my %snapshots = getActive($lv,$vg);
 
	# Удаляем неактивные снапшоты в принципе и снапшоты с неизвестными именами из списка
	foreach (keys %snapshots) {
		
		if (! $snapshots{$_} =~ /active/) {
			
			removeSnapshot($_, $vg, $path);
			delete $snapshots{$_};
		}
		if (! /^\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}.\d{2}$/) {
			delete $snapshots{$_};		
		}
	}
	# Все оставшиеся снапшоты пишем в отсортированный список
	@snapshots = sort keys %snapshots;
 
	# Если нужно - удаляем самые старые, чтобы в итоге осталось $count-1 штук
	foreach ( 0..(@snapshots-$count) ) {
		removeSnapshot($snapshots[$_], $vg, $path);
	}
	splice @snapshots, 0, @snapshots-$count+1 if @snapshots-$count+1 > 0;
 
	# Теперь проверяем, не надо ли чего увеличить в размерах
	foreach (@snapshots) {
		checkSize($_, $vg, $sn_limit, $sn_add);
	}
 
	# А теперь создаём новый снапшотик
	createSnapshot($lv, $vg, $path, $sn_size);
}
 
# Пытаемся примонтировать все снапшоты для указанного тома в указанной группе в их целевые каталоги в path
sub snapshotsRemount {
	@_ == 3 or die "snapshotsRemount - OOPS!\n";
	my ($lv, $vg, $path) = @_;
 
	my %snapshots = getActive($lv,$vg);
 
	# Удаляем неактивные снапшоты в принципе и снапшоты с неизвестными именами из списка
	foreach (keys %snapshots) {
		if (! $snapshots{$_} =~ /active/) {
			removeSnapshot($_, $vg, $path);
			delete $snapshots{$_};
		}
		if (! /^\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}.\d{2}$/) {
			delete $snapshots{$_};		
		}
	}
 
	my @mounted = getMounted($vg,$path);
	my @listed = getListed($path);
 
	# Монтируем все снапшоты в предназначенные для них директории
	foreach my $sn_name (keys %snapshots) {
		unless (isIn($sn_name, @listed)) {
			mkdir "$path/\@GMT-$sn_name", 0777 or die "I can't create a directory for snapshot $sn_name! ($!)\n";		
		}
		unless (isIn($sn_name, @mounted)) {
			if (system "mount -o ro,acl,user_xattr /dev/$vg/$sn_name $path/\@GMT-$sn_name") {
				rmdir "$path/\@GMT-$sn_name" or warn "Very big error: I can't remove a directory for snapshot $sn_name!:(\n";
				die "I can't mount a snapshot $sn_name to it's directory!\n";
			}
		}
	}
 
	# Удаляем директории, для которых нету снапшотов
	foreach (@listed) {
		unless (isIn($_, keys %snapshots)) {
			rmdir "$path/\@GMT-$_" or die "Error: I can't remove an unused directory $_!:(\n";
		}
	}
}
 
# Удаляет все снапшоты для заданного тома
sub removeAllSnapshots {
	@_ == 3 or die "removeAllSnapshots - OOPS!\n";
	my ($lv, $vg, $path) = @_;
	
	my %snapshots = getActive($lv, $vg);
 	
	# Удаляем все снапшоты
	foreach (keys %snapshots) {
		removeSnapshot($_, $vg, $path);
	}
}
 
# pm же!
1;
