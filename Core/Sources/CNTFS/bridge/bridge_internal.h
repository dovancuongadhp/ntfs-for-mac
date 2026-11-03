#ifndef NTFS_BRIDGE_INTERNAL_H
#define NTFS_BRIDGE_INTERNAL_H

#include "ntfs_bridge.h"

typedef struct nb_device_state {
	nb_device_callbacks callbacks;
	long long position;
} nb_device_state;

extern struct ntfs_device_operations nb_device_ops;

#endif /* NTFS_BRIDGE_INTERNAL_H */
