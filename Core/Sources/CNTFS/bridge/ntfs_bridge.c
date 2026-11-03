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
	/* Per file, the end of the highest range handed to the kernel for
	 * writing that may still be in flight above initialized_size. */
	struct nb_pending_write {
		MFT_REF ref;
		s64 end;
	} *pending;
	size_t pending_count;
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
	free(v->pending);
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

/*
 * Compressed and encrypted data can't be handed to the kernel. On a
 * read-only volume, resident data can't be moved out of the MFT record and
 * the partly initialized block at initialized_size can't be zeroed.
 */
static int is_mappable(ntfs_inode *ni)
{
	ntfs_attr *na;
	int mappable;

	if (ni->flags & FILE_ATTR_REPARSE_POINT)
		return 0;
	na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
	if (!na)
		return 0;
	mappable = !(na->data_flags & (ATTR_COMPRESSION_MASK | ATTR_IS_ENCRYPTED));
	if (NVolReadOnly(ni->vol) && (!NAttrNonResident(na)
			|| na->initialized_size < na->data_size))
		mappable = 0;
	ntfs_attr_close(na);
	return mappable;
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
		out->mappable = (uint32_t)is_mappable(ni);
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

static MFT_REF file_ref(ntfs_inode *ni)
{
	return MK_MREF(ni->mft_no, le16_to_cpu(ni->mrec->sequence_number));
}

static struct nb_pending_write *find_pending_write(nb_volume *v,
		ntfs_inode *ni)
{
	MFT_REF ref = file_ref(ni);
	size_t i;

	for (i = 0; i < v->pending_count; i++)
		if (v->pending[i].ref == ref)
			return &v->pending[i];
	return NULL;
}

static s64 pending_write_end(nb_volume *v, ntfs_inode *ni)
{
	struct nb_pending_write *p = find_pending_write(v, ni);

	return p ? p->end : 0;
}

static int set_pending_write_end(nb_volume *v, ntfs_inode *ni, s64 end)
{
	struct nb_pending_write *p = find_pending_write(v, ni);
	struct nb_pending_write *grown;

	if (p) {
		p->end = end;
		return 0;
	}
	grown = realloc(v->pending, (v->pending_count + 1) * sizeof(*grown));
	if (!grown) {
		errno = ENOMEM;
		return -1;
	}
	v->pending = grown;
	v->pending[v->pending_count].ref = file_ref(ni);
	v->pending[v->pending_count].end = end;
	v->pending_count++;
	return 0;
}

static void drop_pending_write(nb_volume *v, ntfs_inode *ni)
{
	struct nb_pending_write *p = find_pending_write(v, ni);

	if (p)
		*p = v->pending[--v->pending_count];
}

/* Writes in flight past a new end of file are dead. */
static void clamp_pending_write(nb_volume *v, ntfs_inode *ni, s64 size)
{
	struct nb_pending_write *p = find_pending_write(v, ni);

	if (p && p->end > size)
		p->end = size;
}

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
	clamp_pending_write(v, ni, (s64)size);
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

/* ------------------------------------------------- kernel-offloaded I/O */

/*
 * Adapted from NTFSKit (https://github.com/whereteam/ntfskit, GPL-2.0).
 *
 * Writes: nb_blockmap allocates solid clusters for the range without
 * writing data, and leaves initialized_size behind; nb_complete_write moves
 * it forward once the kernel's write has landed. Bytes between
 * initialized_size and a newly mapped range are zeroed at map time, but
 * never [initialized_size, pending end): those ranges are already handed
 * out and may still be in flight, and completions arrive out of order.
 */

static const char zeros[65536];

/* Zeroes [from, to) directly on the attribute's clusters, leaving
 * initialized_size alone (ntfs_attr_pwrite would zero-fill from it). */
static int zero_clusters(ntfs_volume *vol, ntfs_attr *na, s64 from, s64 to)
{
	s64 csize = vol->cluster_size;
	runlist_element *rl;

	for (rl = na->rl; rl && rl->length; rl++) {
		s64 start, end, pos;

		if (rl->lcn < 0)
			continue;
		start = rl->vcn * csize > from ? rl->vcn * csize : from;
		end = (rl->vcn + rl->length) * csize < to
			? (rl->vcn + rl->length) * csize : to;
		for (pos = start; pos < end; ) {
			s64 chunk = end - pos < (s64)sizeof(zeros)
				? end - pos : (s64)sizeof(zeros);

			if (ntfs_pwrite(vol->dev, rl->lcn * csize
					+ (pos - rl->vcn * csize), chunk, zeros)
					!= chunk)
				return -1;
			pos += chunk;
		}
	}
	return 0;
}

/* Zero-fills [from, to) through libntfs-3g, which allocates holes and moves
 * initialized_size past the range. */
static int zero_fill(ntfs_attr *na, s64 from, s64 to)
{
	while (from < to) {
		s64 chunk = to - from < (s64)sizeof(zeros)
			? to - from : (s64)sizeof(zeros);

		if (ntfs_attr_pwrite(na, from, chunk, zeros) != chunk)
			return -1;
		from += chunk;
	}
	return 0;
}

/* Writes initialized_size straight into the attribute record. */
static int set_initialized_size(ntfs_attr *na, s64 size)
{
	ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(na->ni, NULL);

	if (!ctx)
		return -1;
	if (ntfs_attr_lookup(na->type, na->name, na->name_len, CASE_SENSITIVE,
			0, NULL, 0, ctx)) {
		ntfs_attr_put_search_ctx(ctx);
		return -1;
	}
	ctx->attr->initialized_size = cpu_to_sle64(size);
	na->initialized_size = size;
	ntfs_inode_mark_dirty(ctx->ntfs_ino);
	ntfs_attr_put_search_ctx(ctx);
	return 0;
}

/* Rejects on-disk runlists whose arithmetic would overflow, that point
 * outside the volume, or that skip VCNs. */
static int bad_runlist(ntfs_volume *vol, const runlist_element *rl)
{
	s64 csize = vol->cluster_size;
	s64 next_vcn = -1;

	for (; rl && rl->length; rl++) {
		if (rl->lcn < LCN_HOLE || rl->length <= 0 || rl->vcn < 0
		    || rl->vcn > INT64_MAX / csize
		    || rl->length > INT64_MAX / csize - rl->vcn)
			return 1;
		if (rl->lcn >= 0 && (rl->lcn >= vol->nr_clusters
		    || rl->length > vol->nr_clusters - rl->lcn))
			return 1;
		if (next_vcn >= 0 && rl->vcn != next_vcn)
			return 1;
		next_vcn = rl->vcn + rl->length;
	}
	return 0;
}

static int map_runlist(ntfs_volume *vol, ntfs_attr *na)
{
	if (ntfs_attr_map_whole_runlist(na))
		return -1;
	if (bad_runlist(vol, na->rl)) {
		errno = EIO;
		return -1;
	}
	return 0;
}

/* Gives holes inside [offset, end) real clusters. */
static int fill_holes(nb_volume *v, ntfs_inode *ni, ntfs_attr *na,
		s64 offset, s64 end)
{
	s64 csize = v->vol->cluster_size;
	s64 pending = pending_write_end(v, ni);

	for (;;) {
		s64 start = -1, stop = -1;
		runlist_element *rl;

		for (rl = na->rl; rl && rl->length; rl++) {
			s64 s, e;

			if (rl->lcn != LCN_HOLE)
				continue;
			s = rl->vcn * csize > offset ? rl->vcn * csize : offset;
			e = (rl->vcn + rl->length) * csize < end
				? (rl->vcn + rl->length) * csize : end;
			if (e > s) {
				start = s;
				stop = e;
				break;
			}
		}
		if (start < 0)
			return 0;
		/* Filling past initialized_size zeroes from it, which must not
		 * reach ranges still in flight. */
		if (pending > na->initialized_size && start > na->initialized_size)
			na->initialized_size = pending;
		/* Filling reallocates the runlist: map it again and rescan. */
		if (zero_fill(na, start, stop) || map_runlist(v->vol, na))
			return -1;
	}
}

static int map_extents(nb_volume *v, ntfs_attr *na, s64 offset, s64 end,
		s64 readable_end, nb_extent_fn fn, void *context, s64 *covered,
		int *stopped)
{
	s64 csize = v->vol->cluster_size;
	runlist_element *rl;

	*covered = offset;
	*stopped = 0;
	for (rl = na->rl; rl && rl->length && !*stopped; rl++) {
		s64 run_start = rl->vcn * csize;
		s64 run_end = run_start + rl->length * csize;
		s64 phys = rl->lcn >= 0 ? rl->lcn * csize : -1;
		s64 start = run_start > offset ? run_start : offset;
		s64 stop = run_end < end ? run_end : end;

		if (stop <= start)
			continue;
		if (phys >= 0 && start < readable_end && stop > readable_end) {
			/* Data below initialized_size, zeros above. */
			if (fn(context, (uint64_t)start, phys + (start - run_start),
					(uint64_t)(readable_end - start))) {
				*covered = readable_end;
				*stopped = 1;
				break;
			}
			start = readable_end;
		}
		if (phys < 0 || start >= readable_end)
			*stopped = fn(context, (uint64_t)start, -1,
					(uint64_t)(stop - start)) != 0;
		else
			*stopped = fn(context, (uint64_t)start,
					phys + (start - run_start),
					(uint64_t)(stop - start)) != 0;
		*covered = stop;
	}
	return 0;
}

int nb_blockmap(nb_volume *v, uint64_t id, uint64_t offset, uint64_t length,
		int for_write, uint32_t block_size, nb_extent_fn fn, void *context)
{
	ntfs_volume *vol = v->vol;
	s64 start = (s64)offset, end, readable_end = INT64_MAX;
	s64 bs = block_size >= 512 ? block_size : 512;
	s64 initialized = -1, covered;
	ntfs_inode *ni;
	ntfs_attr *na;
	int res = 0, stopped;

	if (length == 0)
		return 0;
	if (offset > INT64_MAX || length > (uint64_t)(INT64_MAX - (s64)offset))
		return -EINVAL;
	end = start + (s64)length;
	if (vol->cluster_size % bs)
		return -EOPNOTSUPP;
	if (for_write && NVolReadOnly(vol))
		return -EROFS;
	ni = open_inode(v, id);
	if (!ni)
		return fail();
	na = open_data(ni);
	if (!na) {
		res = fail();
		goto out;
	}
	if (na->data_flags & (ATTR_COMPRESSION_MASK | ATTR_IS_ENCRYPTED)) {
		res = -EOPNOTSUPP;
		goto close_attr;
	}
	/* Small files live inside the MFT record; give them clusters. */
	if (!NAttrNonResident(na)) {
		if (NVolReadOnly(vol)) {
			res = -EOPNOTSUPP;
			goto close_attr;
		}
		if (ntfs_attr_force_non_resident(na)) {
			res = fail();
			goto close_attr;
		}
	}
	if (for_write && end > na->data_size
	    && ntfs_attr_truncate_solid(na, end)) {
		res = fail();
		goto close_attr;
	}
	if (map_runlist(vol, na)) {
		res = fail();
		goto close_attr;
	}

	if (for_write) {
		s64 pending = pending_write_end(v, ni);

		/* Bytes between the written part and this range must read as
		 * zeros once later completions cover them. */
		if (pending <= na->initialized_size) {
			if (zero_fill(na, na->initialized_size, start)
			    || map_runlist(vol, na)) {
				res = fail();
				goto close_attr;
			}
		} else if (start > pending
			   && zero_clusters(vol, na, pending, start)) {
			res = fail();
			goto close_attr;
		}
		initialized = na->initialized_size;
		if (fill_holes(v, ni, na, start, end)) {
			res = fail();
			goto close_attr;
		}
		/* Filling holes moved initialized_size over ranges that haven't
		 * landed; completions move it forward again. */
		if (na->initialized_size > initialized
		    && set_initialized_size(na, initialized)) {
			res = fail();
			goto close_attr;
		}
	} else {
		/* Past initialized_size the data reads as zeros. Extents are
		 * block-aligned, so zero the rest of the last block on disk. */
		readable_end = na->initialized_size;
		if (readable_end % bs) {
			s64 block_end = readable_end + (bs - readable_end % bs);

			if (block_end > na->data_size)
				block_end = na->data_size;
			if (block_end > readable_end
			    && pending_write_end(v, ni) <= readable_end) {
				if (NVolReadOnly(vol)) {
					res = -EOPNOTSUPP;
					goto close_attr;
				}
				if (zero_fill(na, readable_end, block_end)
				    || map_runlist(vol, na)) {
					res = fail();
					goto close_attr;
				}
			}
			readable_end = ((na->initialized_size + bs - 1) / bs) * bs;
		}
	}

	map_extents(v, na, start, end, readable_end, fn, context, &covered,
			&stopped);
	if (!stopped && covered < end) {
		/* Writes need clusters for the whole range; reads past the last
		 * run are zeros. */
		if (for_write)
			res = -EIO;
		else
			fn(context, (uint64_t)covered, -1,
					(uint64_t)(end - covered));
	}
	if (res == 0 && for_write) {
		s64 mapped_end = stopped ? covered : end;

		if (mapped_end > pending_write_end(v, ni)
		    && mapped_end > na->initialized_size
		    && set_pending_write_end(v, ni, mapped_end))
			res = fail();
	}
close_attr:
	if (initialized >= 0 && na->initialized_size > initialized)
		(void)set_initialized_size(na, initialized);
	ntfs_attr_close(na);
	/* The runlist must be on disk before the kernel writes the clusters. */
	if (ntfs_inode_sync(ni))
		keep_error(&res);
out:
	close_inode(ni, &res);
	return res;
}

int nb_complete_write(nb_volume *v, uint64_t id, uint64_t offset,
		uint64_t length)
{
	ntfs_inode *ni;
	ntfs_attr *na;
	s64 start = (s64)offset, target, floor;
	int res = 0;

	if (length == 0)
		return 0;
	if (offset > INT64_MAX || length > (uint64_t)(INT64_MAX - (s64)offset))
		return -EINVAL;
	ni = open_inode(v, id);
	if (!ni)
		return fail();
	na = open_data(ni);
	if (!na) {
		res = fail();
		goto out;
	}
	/* Truncated below the range while the write was in flight. */
	if (start >= na->data_size)
		goto close_attr;
	target = start + (s64)length;
	if (target > na->data_size)
		target = na->data_size;
	if (NAttrNonResident(na)) {
		/* A completion without a blockmap: nothing zeroed the gap. */
		floor = na->initialized_size;
		if (pending_write_end(v, ni) > floor)
			floor = pending_write_end(v, ni);
		if (start > floor && (map_runlist(v->vol, na)
		    || zero_clusters(v->vol, na, floor, start))) {
			res = fail();
			goto close_attr;
		}
		if (na->initialized_size < target
		    && set_initialized_size(na, target)) {
			res = fail();
			goto close_attr;
		}
	}
	if (na->initialized_size >= pending_write_end(v, ni))
		drop_pending_write(v, ni);
	ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
	set_archive(ni);
close_attr:
	ntfs_attr_close(na);
	if (ntfs_inode_sync(ni))
		keep_error(&res);
out:
	close_inode(ni, &res);
	return res;
}

int nb_abort_write(nb_volume *v, uint64_t id, uint64_t offset,
		uint64_t length)
{
	struct nb_pending_write *p;
	ntfs_inode *ni;
	ntfs_attr *na;
	s64 start = (s64)offset, end;
	int res = 0;

	if (offset > INT64_MAX || length > (uint64_t)(INT64_MAX - (s64)offset))
		return -EINVAL;
	end = start + (s64)length;
	ni = open_inode(v, id);
	if (!ni)
		return fail();
	p = find_pending_write(v, ni);
	if (p && start < p->end) {
		na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
		if (end >= p->end) {
			/* The top range failed: later maps zero it again. */
			p->end = start;
			if (!na || p->end <= na->initialized_size)
				drop_pending_write(v, ni);
		} else if (na && NAttrNonResident(na)) {
			/* A lower range failed while higher ones may land: zero
			 * it, or a later completion would expose stale clusters. */
			s64 from = start > na->initialized_size
				? start : na->initialized_size;

			if (from < end && (map_runlist(v->vol, na)
			    || zero_clusters(v->vol, na, from, end)))
				res = fail();
		}
		if (na)
			ntfs_attr_close(na);
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

/* ---------------------------------------------------------------- xattrs */

static ntfs_inode *open_xattr_owner(nb_volume *v, uint64_t id, int writing)
{
	if (writing && NVolReadOnly(v->vol)) {
		errno = EROFS;
		return NULL;
	}
	return open_inode(v, id);
}

int nb_xattr_list(nb_volume *v, uint64_t id, void *context, nb_xattr_fn fn)
{
	ntfs_inode *ni;
	ntfs_attr_search_ctx *ctx;
	int res = 0;

	ni = open_xattr_owner(v, id, 0);
	if (!ni)
		return fail();
	ctx = ntfs_attr_get_search_ctx(ni, NULL);
	if (!ctx) {
		res = fail();
		goto out;
	}
	while (!ntfs_attr_lookup(AT_DATA, NULL, 0, CASE_SENSITIVE, 0, NULL, 0,
			ctx)) {
		ATTR_RECORD *a = ctx->attr;
		char *name = NULL;
		int stop;

		/* Extents of one large stream repeat its name. */
		if (!a->name_length || (a->non_resident && a->lowest_vcn))
			continue;
		if (ntfs_ucstombs((ntfschar *)((u8 *)a
				+ le16_to_cpu(a->name_offset)),
				a->name_length, &name, 0) < 0)
			continue;
		stop = fn(context, name);
		free(name);
		if (stop)
			break;
	}
	ntfs_attr_put_search_ctx(ctx);
out:
	close_inode(ni, &res);
	return res;
}

int64_t nb_xattr_get(nb_volume *v, uint64_t id, const char *name,
		void *buffer, uint64_t buffer_size)
{
	ntfs_inode *ni;
	ntfs_attr *na;
	ntfschar *uname;
	int64_t size = 0;
	int len, res = 0;

	ni = open_xattr_owner(v, id, 0);
	if (!ni)
		return fail();
	len = to_unicode(v, name, &uname, FALSE);
	if (len < 0) {
		res = len;
		goto out;
	}
	na = ntfs_attr_open(ni, AT_DATA, uname, len);
	if (!na) {
		res = errno == ENOENT ? -ENOATTR : fail();
		goto free_name;
	}
	size = na->data_size;
	if (buffer) {
		if ((uint64_t)size > buffer_size)
			res = -ERANGE;
		else if (size && ntfs_attr_pread(na, 0, size, buffer) != size)
			res = errno ? -errno : -EIO;
	}
	ntfs_attr_close(na);
free_name:
	free(uname);
out:
	close_inode(ni, &res);
	return res < 0 ? res : size;
}

int nb_xattr_set(nb_volume *v, uint64_t id, const char *name,
		const void *value, uint64_t size, nb_xattr_mode mode)
{
	ntfs_inode *ni;
	ntfs_attr *na;
	ntfschar *uname;
	int len, exists, res = 0;

	ni = open_xattr_owner(v, id, 1);
	if (!ni)
		return fail();
	len = to_unicode(v, name, &uname, FALSE);
	if (len < 0) {
		res = len;
		goto out;
	}
	exists = ntfs_attr_exist(ni, AT_DATA, uname, len);
	if (exists && mode == NB_XATTR_CREATE) {
		res = -EEXIST;
	} else if (!exists && mode == NB_XATTR_REPLACE) {
		res = -ENOATTR;
	} else if (!exists) {
		if (ntfs_attr_add(ni, AT_DATA, uname, len, (const u8 *)value,
				(s64)size))
			res = fail();
	} else {
		na = ntfs_attr_open(ni, AT_DATA, uname, len);
		if (!na) {
			res = fail();
		} else {
			if (ntfs_attr_truncate(na, 0))
				res = fail();
			else if (size && ntfs_attr_pwrite(na, 0, (s64)size,
					value) != (s64)size)
				res = errno ? -errno : -EIO;
			ntfs_attr_close(na);
		}
	}
	if (res == 0)
		ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
	free(uname);
out:
	close_inode(ni, &res);
	return res;
}

int nb_xattr_remove(nb_volume *v, uint64_t id, const char *name)
{
	ntfs_inode *ni;
	ntfschar *uname;
	int len, res = 0;

	ni = open_xattr_owner(v, id, 1);
	if (!ni)
		return fail();
	len = to_unicode(v, name, &uname, FALSE);
	if (len < 0) {
		res = len;
		goto out;
	}
	if (!ntfs_attr_exist(ni, AT_DATA, uname, len))
		res = -ENOATTR;
	else if (ntfs_attr_remove(ni, AT_DATA, uname, len))
		res = fail();
	else
		ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
	free(uname);
out:
	close_inode(ni, &res);
	return res;
}
