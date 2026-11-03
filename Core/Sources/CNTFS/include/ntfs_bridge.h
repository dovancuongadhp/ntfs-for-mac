/*
 * ntfs_bridge.h - minimal, inode-number based API over libntfs-3g.
 *
 * All functions return 0 (or a non-negative count) on success and a negative
 * errno value on failure. Item identifiers are NTFS MFT record numbers; the
 * root directory is NB_ROOT_ID. A volume handle must only be used from one
 * thread at a time.
 */
#ifndef NTFS_BRIDGE_H
#define NTFS_BRIDGE_H

#include <stdint.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NB_ROOT_ID 5ULL

typedef struct nb_volume nb_volume;

typedef struct nb_device_callbacks {
	void *context;
	uint64_t size;
	uint32_t sector_size;
	int writable;
	/* Return bytes transferred or a negative errno. Offsets and counts
	 * passed here are always multiples of sector_size. */
	int64_t (*read)(void *context, void *buf, uint64_t count, uint64_t offset);
	int64_t (*write)(void *context, const void *buf, uint64_t count, uint64_t offset);
	int (*sync)(void *context);
} nb_device_callbacks;

typedef enum nb_readonly_reason {
	NB_READ_WRITE = 0,
	NB_RO_REQUESTED = 1,
	NB_RO_HIBERNATED = 2,
	NB_RO_UNCLEAN_JOURNAL = 3,
	NB_RO_DIRTY = 4,
	NB_RO_IO_ERROR = 5,
	NB_RO_DEVICE = 6,
} nb_readonly_reason;

typedef enum nb_item_type {
	NB_TYPE_FILE = 1,
	NB_TYPE_DIRECTORY = 2,
	NB_TYPE_SYMLINK = 3,
} nb_item_type;

/* Raw NTFS FILE_ATTR_* bits that callers care about. */
enum {
	NB_ATTR_READONLY   = 0x0001,
	NB_ATTR_HIDDEN     = 0x0002,
	NB_ATTR_SYSTEM     = 0x0004,
	NB_ATTR_ARCHIVE    = 0x0020,
	NB_ATTR_SPARSE     = 0x0200,
	NB_ATTR_REPARSE    = 0x0400,
	NB_ATTR_COMPRESSED = 0x0800,
	NB_ATTR_ENCRYPTED  = 0x4000,
};

typedef struct nb_attributes {
	uint64_t id;
	uint32_t type;
	uint32_t ntfs_flags;
	uint64_t size;
	uint64_t alloc_size;
	uint32_t link_count;
	struct timespec access_time;
	struct timespec modify_time;
	struct timespec change_time;
	struct timespec birth_time;
	/* The data can be read and written directly on the device through
	 * extents from nb_blockmap. */
	uint32_t mappable;
} nb_attributes;

typedef struct nb_statistics {
	uint32_t cluster_size;
	uint64_t total_clusters;
	uint64_t free_clusters;
	uint64_t total_files;
	uint64_t free_files;
	uint32_t max_name_length;
} nb_statistics;

/* Return non-zero to stop enumeration. */
typedef int (*nb_dirent_fn)(void *context, const char *name, uint64_t id,
		uint32_t type);

typedef void (*nb_log_fn)(int is_error, const char *message);

void nb_set_log_handler(nb_log_fn handler);

/* Mounting */
int nb_mount(const nb_device_callbacks *device, int read_only,
		nb_volume **out_volume, nb_readonly_reason *out_reason);
int nb_unmount(nb_volume *volume);
/*
 * Empties an unclean $LogFile so the volume can be mounted read-write.
 * Refuses volumes that are hibernated (-EPERM) or flagged for chkdsk (-EBUSY).
 */
int nb_reset_journal(const nb_device_callbacks *device);
int nb_is_read_only(nb_volume *volume);
void nb_force_read_only(nb_volume *volume);
int nb_sync(nb_volume *volume);
int nb_get_label(nb_volume *volume, char *buffer, uint32_t buffer_size);
int nb_set_label(nb_volume *volume, const char *label);
uint64_t nb_get_serial(nb_volume *volume);
int nb_statistics_get(nb_volume *volume, nb_statistics *out);
/* Absolute symlink and junction targets are resolved relative to this. */
void nb_set_mount_point(nb_volume *volume, const char *path);

/* Items */
int nb_get_attributes(nb_volume *volume, uint64_t id, nb_attributes *out);
int nb_lookup(nb_volume *volume, uint64_t dir_id, const char *name,
		uint64_t *out_id);
int nb_read_directory(nb_volume *volume, uint64_t dir_id, void *context,
		nb_dirent_fn fn);
int nb_create(nb_volume *volume, uint64_t dir_id, const char *name,
		nb_item_type type, uint64_t *out_id);
int nb_remove(nb_volume *volume, uint64_t dir_id, const char *name);
int nb_rename(nb_volume *volume, uint64_t src_dir_id, const char *name,
		uint64_t dst_dir_id, const char *new_name);
int nb_read_link(nb_volume *volume, uint64_t id, char *buffer,
		uint32_t buffer_size);

/* Data */
int64_t nb_read(nb_volume *volume, uint64_t id, void *buffer, uint64_t count,
		uint64_t offset);
int64_t nb_write(nb_volume *volume, uint64_t id, const void *buffer,
		uint64_t count, uint64_t offset);
int nb_truncate(nb_volume *volume, uint64_t id, uint64_t size);
/* Finishes pending work on a file (compresses the last chunk of a
 * compressed file). Call when the last writer closes the file. */
int nb_close_file(nb_volume *volume, uint64_t id);

/*
 * Kernel-offloaded I/O: the kernel transfers file data itself, using the
 * extents the file system hands out.
 *
 * nb_blockmap reports the extents covering [offset, offset + length) through
 * fn, in order. A negative physical offset means the range reads as zeros.
 * For writes it first allocates clusters for the whole range; the data then
 * only counts as written once nb_complete_write records it. Returning
 * non-zero from fn stops the mapping early (the caller asks again for the
 * rest). Returns -EOPNOTSUPP for files that can't be mapped.
 */
typedef int (*nb_extent_fn)(void *context, uint64_t logical,
		int64_t physical, uint64_t length);

int nb_blockmap(nb_volume *volume, uint64_t id, uint64_t offset,
		uint64_t length, int for_write, uint32_t block_size,
		nb_extent_fn fn, void *context);
int nb_complete_write(nb_volume *volume, uint64_t id, uint64_t offset,
		uint64_t length);
/* The kernel failed to write a range handed out by nb_blockmap. */
int nb_abort_write(nb_volume *volume, uint64_t id, uint64_t offset,
		uint64_t length);

/* Metadata. Pass NULL to leave a time unchanged. */
int nb_set_times(nb_volume *volume, uint64_t id,
		const struct timespec *access_time,
		const struct timespec *modify_time,
		const struct timespec *birth_time);
int nb_set_flag(nb_volume *volume, uint64_t id, uint32_t ntfs_flag, int on);

/*
 * Extended attributes, stored as named $DATA streams (alternate data
 * streams). Names are stream names in UTF-8; a missing one is -ENOATTR.
 */
typedef enum {
	NB_XATTR_ANY = 0,
	NB_XATTR_CREATE = 1,	/* fail with -EEXIST if it exists */
	NB_XATTR_REPLACE = 2,	/* fail with -ENOATTR if it doesn't */
} nb_xattr_mode;

/* Return non-zero to stop listing. */
typedef int (*nb_xattr_fn)(void *context, const char *name);

int nb_xattr_list(nb_volume *volume, uint64_t id, void *context,
		nb_xattr_fn fn);
/* Returns the value's size; copies it when buffer is non-NULL (-ERANGE if
 * buffer_size is too small). */
int64_t nb_xattr_get(nb_volume *volume, uint64_t id, const char *name,
		void *buffer, uint64_t buffer_size);
int nb_xattr_set(nb_volume *volume, uint64_t id, const char *name,
		const void *value, uint64_t size, nb_xattr_mode mode);
int nb_xattr_remove(nb_volume *volume, uint64_t id, const char *name);

#ifdef __cplusplus
}
#endif

#endif /* NTFS_BRIDGE_H */
