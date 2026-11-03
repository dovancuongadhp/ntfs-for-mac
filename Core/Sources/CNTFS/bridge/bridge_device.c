/*
 * Callback-backed ntfs_device_operations.
 *
 * libntfs-3g issues byte-granular reads and writes; block devices exposed by
 * FSKit only accept sector-aligned transfers, so unaligned requests go through
 * a bounce buffer (read-modify-write for writes).
 */
#include "config.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/stat.h>

#include "types.h"
#include "device.h"

#include "bridge_internal.h"

static nb_device_state *state_of(struct ntfs_device *dev)
{
	return (nb_device_state *)dev->d_private;
}

static int set_errno_from(int64_t result)
{
	errno = (int)-result;
	return -1;
}

static int64_t aligned_read(nb_device_state *st, void *buf, uint64_t count,
		uint64_t offset)
{
	const nb_device_callbacks *cb = &st->callbacks;
	uint64_t done = 0;

	while (done < count) {
		int64_t r = cb->read(cb->context, (char *)buf + done,
				count - done, offset + done);
		if (r < 0)
			return r;
		if (r == 0)
			break;
		done += (uint64_t)r;
	}
	return (int64_t)done;
}

static int64_t aligned_write(nb_device_state *st, const void *buf,
		uint64_t count, uint64_t offset)
{
	const nb_device_callbacks *cb = &st->callbacks;
	uint64_t done = 0;

	while (done < count) {
		int64_t r = cb->write(cb->context, (const char *)buf + done,
				count - done, offset + done);
		if (r < 0)
			return r;
		if (r == 0)
			return -EIO;
		done += (uint64_t)r;
	}
	return (int64_t)done;
}

static s64 device_pread(struct ntfs_device *dev, void *buf, s64 count,
		s64 offset)
{
	nb_device_state *st = state_of(dev);
	uint64_t ss = st->callbacks.sector_size;
	uint64_t size = st->callbacks.size;
	uint64_t start, end, n;
	int64_t r;
	char *bounce;

	if (count < 0 || offset < 0) {
		errno = EINVAL;
		return -1;
	}
	if ((uint64_t)offset >= size || count == 0)
		return 0;
	n = (uint64_t)count;
	if ((uint64_t)offset + n > size)
		n = size - (uint64_t)offset;

	if ((uint64_t)offset % ss == 0 && n % ss == 0) {
		r = aligned_read(st, buf, n, (uint64_t)offset);
		return r < 0 ? set_errno_from(r) : r;
	}
	start = ((uint64_t)offset / ss) * ss;
	end = (((uint64_t)offset + n + ss - 1) / ss) * ss;
	if (end > size)
		end = size;
	bounce = malloc(end - start);
	if (!bounce) {
		errno = ENOMEM;
		return -1;
	}
	r = aligned_read(st, bounce, end - start, start);
	if (r < 0) {
		free(bounce);
		return set_errno_from(r);
	}
	if ((uint64_t)r < (uint64_t)offset - start) {
		free(bounce);
		return 0;
	}
	if ((uint64_t)r - ((uint64_t)offset - start) < n)
		n = (uint64_t)r - ((uint64_t)offset - start);
	memcpy(buf, bounce + ((uint64_t)offset - start), n);
	free(bounce);
	return (s64)n;
}

static s64 device_pwrite(struct ntfs_device *dev, const void *buf, s64 count,
		s64 offset)
{
	nb_device_state *st = state_of(dev);
	uint64_t ss = st->callbacks.sector_size;
	uint64_t size = st->callbacks.size;
	uint64_t start, end, n;
	int64_t r;
	char *bounce;

	if (NDevReadOnly(dev)) {
		errno = EROFS;
		return -1;
	}
	if (count < 0 || offset < 0) {
		errno = EINVAL;
		return -1;
	}
	if (count == 0)
		return 0;
	n = (uint64_t)count;
	if ((uint64_t)offset + n > size) {
		errno = ENOSPC;
		return -1;
	}
	NDevSetDirty(dev);

	if ((uint64_t)offset % ss == 0 && n % ss == 0) {
		r = aligned_write(st, buf, n, (uint64_t)offset);
		return r < 0 ? set_errno_from(r) : r;
	}
	start = ((uint64_t)offset / ss) * ss;
	end = (((uint64_t)offset + n + ss - 1) / ss) * ss;
	if (end > size) {
		errno = EIO;
		return -1;
	}
	bounce = malloc(end - start);
	if (!bounce) {
		errno = ENOMEM;
		return -1;
	}
	r = aligned_read(st, bounce, end - start, start);
	if (r < 0 || (uint64_t)r != end - start) {
		free(bounce);
		return set_errno_from(r < 0 ? r : -EIO);
	}
	memcpy(bounce + ((uint64_t)offset - start), buf, n);
	r = aligned_write(st, bounce, end - start, start);
	free(bounce);
	if (r < 0)
		return set_errno_from(r);
	return (s64)n;
}

static int device_open(struct ntfs_device *dev, int flags)
{
	nb_device_state *st = state_of(dev);

	if (NDevOpen(dev)) {
		errno = EBUSY;
		return -1;
	}
	if ((flags & O_ACCMODE) != O_RDONLY && !st->callbacks.writable) {
		errno = EROFS;
		return -1;
	}
	if ((flags & O_ACCMODE) == O_RDONLY)
		NDevSetReadOnly(dev);
	else
		NDevClearReadOnly(dev);
	NDevSetBlock(dev);
	NDevSetOpen(dev);
	st->position = 0;
	return 0;
}

static int device_sync(struct ntfs_device *dev)
{
	nb_device_state *st = state_of(dev);
	int r;

	if (NDevReadOnly(dev) || !NDevDirty(dev))
		return 0;
	r = st->callbacks.sync ? st->callbacks.sync(st->callbacks.context) : 0;
	if (r < 0) {
		errno = -r;
		return -1;
	}
	NDevClearDirty(dev);
	return 0;
}

static int device_close(struct ntfs_device *dev)
{
	if (!NDevOpen(dev)) {
		errno = EBADF;
		return -1;
	}
	if (device_sync(dev))
		return -1;
	NDevClearOpen(dev);
	return 0;
}

static s64 device_seek(struct ntfs_device *dev, s64 offset, int whence)
{
	nb_device_state *st = state_of(dev);
	s64 base;

	switch (whence) {
	case SEEK_SET:
		base = 0;
		break;
	case SEEK_CUR:
		base = st->position;
		break;
	case SEEK_END:
		base = (s64)st->callbacks.size;
		break;
	default:
		errno = EINVAL;
		return -1;
	}
	if (base + offset < 0) {
		errno = EINVAL;
		return -1;
	}
	st->position = base + offset;
	return st->position;
}

static s64 device_read(struct ntfs_device *dev, void *buf, s64 count)
{
	nb_device_state *st = state_of(dev);
	s64 r = device_pread(dev, buf, count, st->position);

	if (r > 0)
		st->position += r;
	return r;
}

static s64 device_write(struct ntfs_device *dev, const void *buf, s64 count)
{
	nb_device_state *st = state_of(dev);
	s64 r = device_pwrite(dev, buf, count, st->position);

	if (r > 0)
		st->position += r;
	return r;
}

static int device_stat(struct ntfs_device *dev, struct stat *buf)
{
	nb_device_state *st = state_of(dev);

	memset(buf, 0, sizeof(*buf));
	buf->st_mode = S_IFBLK;
	buf->st_size = (off_t)st->callbacks.size;
	buf->st_blksize = (blksize_t)st->callbacks.sector_size;
	return 0;
}

static int device_ioctl(struct ntfs_device *dev, unsigned long request,
		void *argp)
{
	nb_device_state *st = state_of(dev);

	switch (request) {
	case DKIOCGETBLOCKSIZE:
		*(uint32_t *)argp = st->callbacks.sector_size;
		return 0;
	case DKIOCGETBLOCKCOUNT:
		*(uint64_t *)argp = st->callbacks.size / st->callbacks.sector_size;
		return 0;
	default:
		errno = ENOTTY;
		return -1;
	}
}

struct ntfs_device_operations nb_device_ops = {
	.open = device_open,
	.close = device_close,
	.seek = device_seek,
	.read = device_read,
	.write = device_write,
	.pread = device_pread,
	.pwrite = device_pwrite,
	.sync = device_sync,
	.stat = device_stat,
	.ioctl = device_ioctl,
};
