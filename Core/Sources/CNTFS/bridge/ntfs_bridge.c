/*
 * ntfs_bridge.c - inode-number based operations over libntfs-3g.
 *
 * The operation sequences mirror src/lowntfs-3g.c (the low-level FUSE
 * driver shipped with ntfs-3g) without the FUSE and permission layers.
 */
#include "config.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "types.h"
#include "attrib.h"
#include "bootsect.h"
#include "device.h"
#include "dir.h"
#include "inode.h"
#include "layout.h"
#include "logging.h"
#include "misc.h"
#include "ntfstime.h"
#include "reparse.h"
#include "unistr.h"
#include "volume.h"

#include "bridge_internal.h"

struct nb_volume {
	ntfs_volume *vol;
	nb_device_state device;
	char *mount_point;
	uint64_t serial;
};

static const char rename_suffix[] = ".ntfs-for-mac-";
static unsigned int rename_sequence;

/* ---------------------------------------------------------------- logging */

static nb_log_fn log_fn;

static int log_handler(const char *function __attribute__((unused)),
		const char *file __attribute__((unused)),
		int line __attribute__((unused)), u32 level,
		void *data __attribute__((unused)), const char *format,
		va_list args)
{
	char message[1024];
	int saved = errno;
	int n;

	if (!log_fn)
		return 0;
	n = vsnprintf(message, sizeof(message), format, args);
	if (n > 0 && (level & NTFS_LOG_LEVEL_PERROR)
	    && (size_t)n < sizeof(message))
		snprintf(message + n, sizeof(message) - (size_t)n, ": %s",
				strerror(saved));
	log_fn((level & (NTFS_LOG_LEVEL_ERROR | NTFS_LOG_LEVEL_PERROR
			| NTFS_LOG_LEVEL_CRITICAL)) != 0, message);
	errno = saved;
	return n;
}

void nb_set_log_handler(nb_log_fn handler)
{
	log_fn = handler;
	ntfs_log_set_handler(log_handler);
	ntfs_log_set_levels(NTFS_LOG_LEVEL_INFO | NTFS_LOG_LEVEL_WARNING
			| NTFS_LOG_LEVEL_ERROR | NTFS_LOG_LEVEL_PERROR
			| NTFS_LOG_LEVEL_CRITICAL);
}

/* ---------------------------------------------------------------- helpers */

static int fail(void)
{
	return errno ? -errno : -EIO;
}

/* Records error into *res unless an error is already recorded. */
static void keep_error(int *res)
{
	if (*res >= 0)
		*res = fail();
}

static int close_inode(ntfs_inode *ni, int *res)
{
	if (ni && ntfs_inode_close(ni)) {
		keep_error(res);
		return -1;
	}
	return 0;
}

static ntfs_inode *open_inode(nb_volume *v, uint64_t id)
{
	if (id < FILE_root || (id < FILE_first_user && id != FILE_root)) {
		errno = ENOENT;
		return NULL;
	}
	return ntfs_inode_open(v->vol, (MFT_REF)id);
}

static int to_unicode(nb_volume *v, const char *name, ntfschar **uname,
		BOOL check_windows_rules)
{
	int len;

	*uname = NULL;
	len = ntfs_mbstoucs(name, uname);
	if (len < 0)
		return fail();
	if (len == 0 || len > NTFS_MAX_NAME_LEN) {
		free(*uname);
		*uname = NULL;
		return len ? -ENAMETOOLONG : -EINVAL;
	}
	if (check_windows_rules && ntfs_forbidden_names(v->vol, *uname, len,
			TRUE)) {
		free(*uname);
		*uname = NULL;
		return -EINVAL;
	}
	return len;
}

static void set_archive(ntfs_inode *ni)
{
	if (!(ni->flags & FILE_ATTR_ARCHIVE)) {
		ni->flags |= FILE_ATTR_ARCHIVE;
		NInoFileNameSetDirty(ni);
		NInoSetDirty(ni);
	}
}

static int lookup_in(ntfs_inode *dir_ni, const char *name, uint64_t *out_id)
{
	u64 iref;

	if (strlen(name) >= 256 * 4)
		return -ENAMETOOLONG;
	iref = ntfs_inode_lookup_by_mbsname(dir_ni, name);
	if (iref == (u64)-1)
		return errno ? -errno : -ENOENT;
	if (MREF(iref) < FILE_first_user)
		return -ENOENT;
	*out_id = MREF(iref);
	return 0;
}

static int is_directory(ntfs_inode *ni)
{
	return (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) != 0;
}

/* ---------------------------------------------------------------- mounting */

static ntfs_volume *mount_with(nb_volume *v, ntfs_mount_flags flags)
{
	struct ntfs_device *dev;
	ntfs_volume *vol;
	int saved;

	dev = ntfs_device_alloc("ntfs-for-mac", 0, &nb_device_ops, &v->device);
	if (!dev)
		return NULL;
	vol = ntfs_device_mount(dev, flags);
	if (!vol) {
		saved = errno;
		ntfs_device_free(dev);
		errno = saved;
	}
	return vol;
}

static uint64_t read_serial(ntfs_volume *vol)
{
	NTFS_BOOT_SECTOR bs;

	if (ntfs_pread(vol->dev, 0, sizeof(bs), &bs) != sizeof(bs))
		return 0;
	return le64_to_cpu(bs.volume_serial_number);
}

static s64 free_mft_records(ntfs_volume *vol)
{
	ntfs_attr *na = vol->mftbmp_na;
	s64 nr_free = ntfs_attr_get_free_bits(na);

	if (nr_free >= 0)
		nr_free += (na->allocated_size - na->data_size) << 3;
	return nr_free;
}

int nb_mount(const nb_device_callbacks *device, int read_only,
		nb_volume **out_volume, nb_readonly_reason *out_reason)
{
	nb_volume *v;
	ntfs_volume *vol;
	nb_readonly_reason reason = NB_READ_WRITE;
	int res;

	if (!device || !out_volume || !device->read || device->sector_size == 0
	    || device->size < 512)
		return -EINVAL;
	v = calloc(1, sizeof(*v));
	if (!v)
		return -ENOMEM;
	v->device.callbacks = *device;

	errno = 0;
	if (read_only || !device->writable) {
		vol = mount_with(v, NTFS_MNT_RDONLY);
		reason = read_only ? NB_RO_REQUESTED : NB_RO_DEVICE;
	} else {
		/*
		 * Inspect read-only first: a volume Windows flagged for chkdsk
		 * must not be touched at all.
		 */
		vol = mount_with(v, NTFS_MNT_RDONLY);
		if (vol && (vol->flags & VOLUME_IS_DIRTY)) {
			reason = NB_RO_DIRTY;
		} else if (vol) {
			ntfs_umount(vol, FALSE);
			vol = mount_with(v, NTFS_MNT_MAY_RDONLY);
			if (vol && NVolReadOnly(vol)) {
				if (ntfs_volume_check_hiberfile(vol, 0) < 0
				    && errno == EPERM)
					reason = NB_RO_HIBERNATED;
				else
					reason = NB_RO_UNCLEAN_JOURNAL;
			}
		}
	}
	if (!vol) {
		res = fail();
		free(v);
		return res;
	}
	v->vol = vol;

	ntfs_set_shown_files(vol, FALSE, TRUE, FALSE);
	ntfs_set_ignore_case(vol);
	if (ntfs_volume_get_free_space(vol)) {
		res = fail();
		ntfs_umount(vol, FALSE);
		free(v);
		return res;
	}
	vol->free_mft_records = free_mft_records(vol);
	v->serial = read_serial(vol);
	v->mount_point = strdup("/");

	*out_volume = v;
	if (out_reason)
		*out_reason = reason;
	return 0;
}

int nb_reset_journal(const nb_device_callbacks *device)
{
	nb_volume v = { 0 };
	ntfs_volume *vol;
	int res;

	if (!device || !device->read || !device->write || device->sector_size == 0
	    || device->size < 512)
		return -EINVAL;
	if (!device->writable)
		return -EROFS;
	v.device.callbacks = *device;

	errno = 0;
	vol = mount_with(&v, NTFS_MNT_RDONLY);
	if (!vol)
		return fail();
	if (vol->flags & VOLUME_IS_DIRTY) {
		ntfs_umount(vol, FALSE);
		return -EBUSY;
	}
	ntfs_umount(vol, FALSE);

	vol = mount_with(&v, NTFS_MNT_MAY_RDONLY);
	if (!vol)
		return fail();
	if (!NVolReadOnly(vol)) {
		ntfs_umount(vol, FALSE);
		return 0;
	}
	/* Windows' memory image still references this volume: never discard it. */
	if (ntfs_volume_check_hiberfile(vol, 0) < 0 && errno == EPERM) {
		ntfs_umount(vol, FALSE);
		return -EPERM;
	}
	/*
	 * The fallback left the device open read-write, so the journal can be
	 * emptied in place, as ntfs-3g's "recover" option does. Unlike that
	 * option, this also covers the version 2.0 restart pages left behind
	 * when a drive is unplugged without ejecting.
	 */
	NVolClearReadOnly(vol);
	res = ntfs_logfile_reset(vol) ? fail() : 0;
	if (ntfs_umount(vol, FALSE) && res == 0)
		res = fail();
	return res;
}

int nb_unmount(nb_volume *v)
{
	int res = 0;

	if (!v)
		return -EINVAL;
	if (ntfs_umount(v->vol, FALSE))
		res = fail();
	free(v->mount_point);
	free(v);
	return res;
}

int nb_is_read_only(nb_volume *v)
{
	return NVolReadOnly(v->vol) ? 1 : 0;
}

void nb_force_read_only(nb_volume *v)
{
	NVolSetReadOnly(v->vol);
}

int nb_sync(nb_volume *v)
{
	if (NVolReadOnly(v->vol))
		return 0;
	if (ntfs_device_sync(v->vol->dev))
		return fail();
	return 0;
}

int nb_get_label(nb_volume *v, char *buffer, uint32_t buffer_size)
{
	const char *name = v->vol->vol_name ? v->vol->vol_name : "";
	size_t len = strlen(name);

	if (buffer_size == 0)
		return -EINVAL;
	if (len >= buffer_size)
		return -ERANGE;
	memcpy(buffer, name, len + 1);
	return (int)len;
}

int nb_set_label(nb_volume *v, const char *label)
{
	ntfschar *ulabel = NULL;
	int len, res = 0;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	len = ntfs_mbstoucs(label, &ulabel);
	if (len < 0)
		return fail();
	if (len > 128) {
		free(ulabel);
		return -ENAMETOOLONG;
	}
	if (ntfs_volume_rename(v->vol, ulabel, len))
		res = fail();
	free(ulabel);
	return res;
}

uint64_t nb_get_serial(nb_volume *v)
{
	return v->serial;
}

int nb_statistics_get(nb_volume *v, nb_statistics *out)
{
	ntfs_volume *vol = v->vol;
	s64 free_clusters = vol->free_clusters < 0 ? 0 : vol->free_clusters;
	s64 free_inodes = free_clusters;
	int delta_bits = vol->cluster_size_bits - vol->mft_record_size_bits;

	if (delta_bits >= 0)
		free_inodes <<= delta_bits;
	else
		free_inodes >>= -delta_bits;
	out->cluster_size = vol->cluster_size;
	out->total_clusters = (uint64_t)vol->nr_clusters;
	out->free_clusters = (uint64_t)free_clusters;
	out->total_files = (uint64_t)((vol->mftbmp_na->allocated_size << 3)
			+ free_inodes);
	free_inodes += vol->free_mft_records;
	out->free_files = free_inodes < 0 ? 0 : (uint64_t)free_inodes;
	out->max_name_length = NTFS_MAX_NAME_LEN;
	return 0;
}

void nb_set_mount_point(nb_volume *v, const char *path)
{
	char *copy = strdup(path ? path : "/");

	if (copy) {
		free(v->mount_point);
		v->mount_point = copy;
	}
}

/* ---------------------------------------------------------------- items */

static char *symlink_target(nb_volume *v, ntfs_inode *ni)
{
	if (!(ni->flags & FILE_ATTR_REPARSE_POINT))
		return NULL;
	errno = 0;
	return ntfs_make_symlink(ni, v->mount_point);
}

static void fill_attributes(nb_volume *v, ntfs_inode *ni, nb_attributes *out)
{
	char *target;
	ntfs_attr *na;

	memset(out, 0, sizeof(*out));
	out->id = ni->mft_no;
	out->ntfs_flags = le32_to_cpu(ni->flags);
	out->link_count = le16_to_cpu(ni->mrec->link_count);

	target = symlink_target(v, ni);
	if (target) {
		out->type = NB_TYPE_SYMLINK;
		out->size = strlen(target);
		out->alloc_size = (uint64_t)((ni->allocated_size + 511) & ~511);
		free(target);
	} else if (is_directory(ni)) {
		out->type = NB_TYPE_DIRECTORY;
		out->link_count = 1;
		na = ntfs_attr_open(ni, AT_INDEX_ALLOCATION, NTFS_INDEX_I30, 4);
		if (na) {
			out->size = (uint64_t)na->data_size;
			out->alloc_size = (uint64_t)na->allocated_size;
			ntfs_attr_close(na);
		}
	} else {
		out->type = NB_TYPE_FILE;
		out->size = (uint64_t)ni->data_size;
		out->alloc_size = (uint64_t)((ni->allocated_size + 511) & ~511);
	}
	out->access_time = ntfs2timespec(ni->last_access_time);
	out->modify_time = ntfs2timespec(ni->last_data_change_time);
	out->change_time = ntfs2timespec(ni->last_mft_change_time);
	out->birth_time = ntfs2timespec(ni->creation_time);
}

int nb_get_attributes(nb_volume *v, uint64_t id, nb_attributes *out)
{
	ntfs_inode *ni;
	int res = 0;

	ni = open_inode(v, id);
	if (!ni)
		return fail();
	fill_attributes(v, ni, out);
	close_inode(ni, &res);
	return res;
}

int nb_lookup(nb_volume *v, uint64_t dir_id, const char *name,
		uint64_t *out_id)
{
	ntfs_inode *dir_ni;
	int res;

	dir_ni = open_inode(v, dir_id);
	if (!dir_ni)
		return fail();
	if (!is_directory(dir_ni)) {
		ntfs_inode_close(dir_ni);
		return -ENOTDIR;
	}
	res = lookup_in(dir_ni, name, out_id);
	close_inode(dir_ni, &res);
	return res;
}

struct readdir_context {
	nb_volume *volume;
	void *context;
	nb_dirent_fn fn;
	int error;
};

static int readdir_filler(void *dirent, const ntfschar *name,
		const int name_len, const int name_type,
		const s64 pos __attribute__((unused)), const MFT_REF mref,
		const unsigned dt_type)
{
	struct readdir_context *rc = dirent;
	char *mbname = NULL;
	uint32_t type;
	ntfs_inode *ni;
	int stop;

	if (name_type == FILE_NAME_DOS)
		return 0;
	if (MREF(mref) < FILE_first_user)
		return 0;
	if ((name_len == 1 && name[0] == const_cpu_to_le16('.'))
	    || (name_len == 2 && name[0] == const_cpu_to_le16('.')
		&& name[1] == const_cpu_to_le16('.')))
		return 0;
	if (ntfs_ucstombs(name, name_len, &mbname, 0) < 0)
		return 0;

	switch (dt_type) {
	case NTFS_DT_DIR:
		type = NB_TYPE_DIRECTORY;
		break;
	case NTFS_DT_LNK:
		type = NB_TYPE_SYMLINK;
		break;
	case NTFS_DT_REPARSE:
		type = NB_TYPE_FILE;
		ni = ntfs_inode_open(rc->volume->vol, MREF(mref));
		if (ni) {
			nb_attributes attrs;

			fill_attributes(rc->volume, ni, &attrs);
			type = attrs.type;
			ntfs_inode_close(ni);
		}
		break;
	default:
		type = NB_TYPE_FILE;
		break;
	}
	stop = rc->fn(rc->context, mbname, MREF(mref), type);
	free(mbname);
	return stop;
}

int nb_read_directory(nb_volume *v, uint64_t dir_id, void *context,
		nb_dirent_fn fn)
{
	struct readdir_context rc = { v, context, fn, 0 };
	ntfs_inode *dir_ni;
	s64 pos = 0;
	int res = 0;

	dir_ni = open_inode(v, dir_id);
	if (!dir_ni)
		return fail();
	if (!is_directory(dir_ni)) {
		ntfs_inode_close(dir_ni);
		return -ENOTDIR;
	}
	/* In ignore-case mode ntfs_readdir() reports lowercased names; list
	 * the names as stored and keep lookups case-insensitive. */
	NVolSetCaseSensitive(v->vol);
	if (ntfs_readdir(dir_ni, &pos, &rc, readdir_filler))
		res = fail();
	NVolClearCaseSensitive(v->vol);
	close_inode(dir_ni, &res);
	return res;
}

int nb_create(nb_volume *v, uint64_t dir_id, const char *name,
		nb_item_type type, uint64_t *out_id)
{
	ntfs_inode *dir_ni, *ni;
	ntfschar *uname;
	uint64_t existing;
	int len, res = 0;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	if (type != NB_TYPE_FILE && type != NB_TYPE_DIRECTORY)
		return -EINVAL;
	if (dir_id == FILE_Extend)
		return -EPERM;
	len = to_unicode(v, name, &uname, TRUE);
	if (len < 0)
		return len;
	dir_ni = open_inode(v, dir_id);
	if (!dir_ni) {
		res = fail();
		goto out;
	}
	if (!is_directory(dir_ni)) {
		res = -ENOTDIR;
		goto close_dir;
	}
	if (lookup_in(dir_ni, name, &existing) == 0) {
		res = -EEXIST;
		goto close_dir;
	}
	ni = ntfs_create(dir_ni, const_cpu_to_le32(0), uname, (u8)len,
			type == NB_TYPE_DIRECTORY ? S_IFDIR : S_IFREG);
	if (!ni) {
		res = fail();
		goto close_dir;
	}
	if (type == NB_TYPE_FILE)
		set_archive(ni);
	ntfs_inode_update_mbsname(dir_ni, name, ni->mft_no);
	NInoSetDirty(ni);
	*out_id = ni->mft_no;
	if (ntfs_inode_close_in_dir(ni, dir_ni))
		keep_error(&res);
	ntfs_inode_update_times(dir_ni, NTFS_UPDATE_MCTIME);
close_dir:
	close_inode(dir_ni, &res);
out:
	free(uname);
	return res;
}

/* Adds name @name in @dir_id for item @id. */
static int add_link(nb_volume *v, uint64_t id, uint64_t dir_id,
		const char *name)
{
	ntfs_inode *ni, *dir_ni = NULL;
	ntfschar *uname = NULL;
	int len, res = 0;

	ni = open_inode(v, id);
	if (!ni)
		return fail();
	len = to_unicode(v, name, &uname, TRUE);
	if (len < 0) {
		res = len;
		goto out;
	}
	dir_ni = open_inode(v, dir_id);
	if (!dir_ni) {
		res = fail();
		goto out;
	}
	if (ntfs_link(ni, dir_ni, uname, (u8)len)) {
		res = fail();
		goto out;
	}
	ntfs_inode_update_mbsname(dir_ni, name, ni->mft_no);
	set_archive(ni);
	ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
	ntfs_inode_update_times(dir_ni, NTFS_UPDATE_MCTIME);
out:
	/* The directory must be closed first so its index is on disk before
	 * the file name copy in the inode is synchronized. */
	close_inode(dir_ni, &res);
	close_inode(ni, &res);
	free(uname);
	return res;
}

int nb_remove(nb_volume *v, uint64_t dir_id, const char *name)
{
	ntfs_inode *dir_ni, *ni;
	ntfschar *uname = NULL;
	uint64_t id;
	int len, res;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	if (dir_id == FILE_Extend)
		return -EPERM;
	dir_ni = open_inode(v, dir_id);
	if (!dir_ni)
		return fail();
	len = to_unicode(v, name, &uname, FALSE);
	if (len < 0) {
		ntfs_inode_close(dir_ni);
		return len;
	}
	res = lookup_in(dir_ni, name, &id);
	if (res < 0) {
		ntfs_inode_close(dir_ni);
		free(uname);
		return res;
	}
	ni = ntfs_inode_open(v->vol, id);
	if (!ni) {
		res = fail();
		ntfs_inode_close(dir_ni);
		free(uname);
		return res;
	}
	/* ntfs_delete() closes both inodes, whatever the outcome. */
	if (ntfs_delete(v->vol, NULL, ni, dir_ni, uname, (u8)len))
		res = fail();
	free(uname);
	return res;
}

/* Returns 1 if @ancestor_id is @dir_id or one of its parents. */
static int is_ancestor(nb_volume *v, uint64_t ancestor_id, uint64_t dir_id)
{
	ntfs_inode *ni, *parent;
	int depth = 0;

	if (ancestor_id == dir_id)
		return 1;
	ni = ntfs_inode_open(v->vol, dir_id);
	while (ni && ni->mft_no != FILE_root && depth++ < 4096) {
		parent = ntfs_dir_parent_inode(ni);
		ntfs_inode_close(ni);
		ni = parent;
		if (ni && ni->mft_no == ancestor_id) {
			ntfs_inode_close(ni);
			return 1;
		}
	}
	if (ni)
		ntfs_inode_close(ni);
	return 0;
}

static char *temporary_name(const char *name)
{
	size_t len = strlen(name) + sizeof(rename_suffix) + 11;
	char *tmp = malloc(len);

	if (tmp)
		snprintf(tmp, len, "%s%s%010u", name, rename_suffix,
				++rename_sequence);
	return tmp;
}

int nb_rename(nb_volume *v, uint64_t src_dir_id, const char *name,
		uint64_t dst_dir_id, const char *new_name)
{
	ntfs_inode *ni, *xni;
	uint64_t id, xid;
	int src_is_dir, res;
	char *tmp;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	res = nb_lookup(v, src_dir_id, name, &id);
	if (res < 0)
		return res;
	ni = ntfs_inode_open(v->vol, id);
	if (!ni)
		return fail();
	src_is_dir = is_directory(ni);
	ntfs_inode_close(ni);
	if (src_is_dir && src_dir_id != dst_dir_id
	    && is_ancestor(v, id, dst_dir_id))
		return -EINVAL;

	res = nb_lookup(v, dst_dir_id, new_name, &xid);
	if (res == -ENOENT) {
		res = add_link(v, id, dst_dir_id, new_name);
		if (res < 0)
			return res;
		res = nb_remove(v, src_dir_id, name);
		if (res < 0)
			nb_remove(v, dst_dir_id, new_name);
		return res;
	}
	if (res < 0)
		return res;

	tmp = temporary_name(new_name);
	if (!tmp)
		return -ENOMEM;

	if (xid == id) {
		/* Same item: case-only rename, or a no-op. */
		if (src_dir_id != dst_dir_id || strcmp(name, new_name) == 0) {
			free(tmp);
			return 0;
		}
		res = add_link(v, id, dst_dir_id, tmp);
		if (res == 0) {
			res = nb_remove(v, src_dir_id, name);
			if (res == 0)
				res = add_link(v, id, dst_dir_id, new_name);
			if (res == 0)
				res = nb_remove(v, dst_dir_id, tmp);
		}
		free(tmp);
		return res;
	}

	/* Replace an existing destination. */
	xni = ntfs_inode_open(v->vol, xid);
	if (!xni) {
		free(tmp);
		return fail();
	}
	if (is_directory(xni) != src_is_dir) {
		ntfs_inode_close(xni);
		free(tmp);
		return src_is_dir ? -ENOTDIR : -EISDIR;
	}
	if (ntfs_check_empty_dir(xni) < 0) {
		res = fail();
		ntfs_inode_close(xni);
		free(tmp);
		return res;
	}
	ntfs_inode_close(xni);

	res = add_link(v, xid, dst_dir_id, tmp);
	if (res < 0)
		goto out;
	res = nb_remove(v, dst_dir_id, new_name);
	if (res == 0) {
		res = add_link(v, id, dst_dir_id, new_name);
		if (res == 0) {
			res = nb_remove(v, src_dir_id, name);
			if (res < 0)
				nb_remove(v, dst_dir_id, new_name);
		}
		if (res < 0) {
			/* Restore the original destination. */
			if (add_link(v, xid, dst_dir_id, new_name) == 0)
				nb_remove(v, dst_dir_id, tmp);
			goto out;
		}
	}
	nb_remove(v, dst_dir_id, tmp);
out:
	free(tmp);
	return res;
}

int nb_read_link(nb_volume *v, uint64_t id, char *buffer, uint32_t buffer_size)
{
	ntfs_inode *ni;
	char *target;
	size_t len;
	int res = 0;

	ni = open_inode(v, id);
	if (!ni)
		return fail();
	target = symlink_target(v, ni);
	if (!target) {
		res = errno == EOPNOTSUPP || !errno ? -EINVAL : fail();
	} else {
		len = strlen(target);
		if (len >= buffer_size)
			res = -ERANGE;
		else {
			memcpy(buffer, target, len + 1);
			res = (int)len;
		}
		free(target);
	}
	close_inode(ni, &res);
	return res;
}

/* ---------------------------------------------------------------- data */

static ntfs_attr *open_data(ntfs_inode *ni)
{
	if (ni->flags & FILE_ATTR_REPARSE_POINT) {
		/* Cloud placeholders, deduplicated and WOF-compressed files
		 * keep their data outside $DATA: refuse rather than return
		 * zeros. */
		errno = EOPNOTSUPP;
		return NULL;
	}
	if (is_directory(ni)) {
		errno = EISDIR;
		return NULL;
	}
	return ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
}

int64_t nb_read(nb_volume *v, uint64_t id, void *buffer, uint64_t count,
		uint64_t offset)
{
	ntfs_inode *ni;
	ntfs_attr *na;
	int64_t total = 0;
	int res = 0;

	ni = open_inode(v, id);
	if (!ni)
		return fail();
	na = open_data(ni);
	if (!na) {
		res = fail();
		goto out;
	}
	if ((s64)offset >= na->data_size)
		goto close_attr;
	if ((s64)(offset + count) > na->data_size)
		count = (uint64_t)(na->data_size - (s64)offset);
	while (count > 0) {
		s64 r = ntfs_attr_pread(na, (s64)offset, (s64)count,
				(char *)buffer + total);
		if (r <= 0 || (uint64_t)r > count) {
			res = r < 0 ? fail() : -EIO;
			break;
		}
		count -= (uint64_t)r;
		offset += (uint64_t)r;
		total += r;
	}
close_attr:
	ntfs_attr_close(na);
out:
	close_inode(ni, &res);
	return res < 0 ? res : total;
}

int64_t nb_write(nb_volume *v, uint64_t id, const void *buffer, uint64_t count,
		uint64_t offset)
{
	ntfs_inode *ni;
	ntfs_attr *na;
	int64_t total = 0;
	int res = 0;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	if (id < FILE_first_user)
		return -EPERM;
	ni = open_inode(v, id);
	if (!ni)
		return fail();
	na = open_data(ni);
	if (!na) {
		res = fail();
		goto out;
	}
	while (count > 0) {
		s64 r = ntfs_attr_pwrite(na, (s64)offset, (s64)count,
				(const char *)buffer + total);
		if (r <= 0) {
			res = r < 0 ? fail() : -EIO;
			break;
		}
		count -= (uint64_t)r;
		offset += (uint64_t)r;
		total += r;
	}
	ntfs_attr_close(na);
	if (total > 0) {
		ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
		set_archive(ni);
	}
out:
	close_inode(ni, &res);
	return res < 0 ? res : total;
}

int nb_truncate(nb_volume *v, uint64_t id, uint64_t size)
{
	ntfs_inode *ni;
	ntfs_attr *na;
	s64 old_size;
	int res = 0;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	if (id < FILE_first_user)
		return -EPERM;
	ni = open_inode(v, id);
	if (!ni)
		return fail();
	na = open_data(ni);
	if (!na) {
		res = fail();
		goto out;
	}
	old_size = na->data_size;
	if ((na->data_flags & ATTR_COMPRESSION_MASK)
	    && (s64)size > na->initialized_size) {
		char zero = 0;

		if (ntfs_attr_pwrite(na, (s64)size - 1, 1, &zero) <= 0)
			res = fail();
	} else if (ntfs_attr_truncate(na, (s64)size)) {
		res = fail();
	}
	ntfs_attr_close(na);
	if (res == 0) {
		if (old_size != (s64)size)
			set_archive(ni);
		ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
	}
out:
	close_inode(ni, &res);
	return res;
}

int nb_close_file(nb_volume *v, uint64_t id)
{
	ntfs_inode *ni;
	ntfs_attr *na;
	int res = 0;

	if (NVolReadOnly(v->vol))
		return 0;
	ni = open_inode(v, id);
	if (!ni)
		return fail();
	if (!(ni->flags & FILE_ATTR_REPARSE_POINT) && !is_directory(ni)) {
		na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
		if (na) {
			if ((na->data_flags & ATTR_COMPRESSION_MASK)
			    && ntfs_attr_pclose(na))
				res = fail();
			ntfs_attr_close(na);
		}
	}
	close_inode(ni, &res);
	return res;
}

/* ---------------------------------------------------------------- metadata */

int nb_set_times(nb_volume *v, uint64_t id, const struct timespec *access_time,
		const struct timespec *modify_time,
		const struct timespec *birth_time)
{
	ntfs_inode *ni;
	int res = 0;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	ni = open_inode(v, id);
	if (!ni)
		return fail();
	if (access_time)
		ni->last_access_time = timespec2ntfs(*access_time);
	if (modify_time)
		ni->last_data_change_time = timespec2ntfs(*modify_time);
	if (birth_time)
		ni->creation_time = timespec2ntfs(*birth_time);
	ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
	NInoFileNameSetDirty(ni);
	NInoSetDirty(ni);
	close_inode(ni, &res);
	return res;
}

int nb_set_flag(nb_volume *v, uint64_t id, uint32_t ntfs_flag, int on)
{
	const uint32_t allowed = NB_ATTR_READONLY | NB_ATTR_HIDDEN
			| NB_ATTR_SYSTEM | NB_ATTR_ARCHIVE;
	ntfs_inode *ni;
	le32 flag;
	int res = 0;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	if (ntfs_flag & ~allowed)
		return -EINVAL;
	ni = open_inode(v, id);
	if (!ni)
		return fail();
	flag = cpu_to_le32(ntfs_flag);
	if (on)
		ni->flags |= flag;
	else
		ni->flags &= ~flag;
	ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
	NInoFileNameSetDirty(ni);
	NInoSetDirty(ni);
	close_inode(ni, &res);
	return res;
}
