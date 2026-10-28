#ifndef ASEQUENCER_MIN_H
#define ASEQUENCER_MIN_H

#include <sys/ioctl.h>

typedef unsigned char snd_seq_event_type_t;
typedef unsigned int snd_seq_tick_time_t;

struct snd_seq_addr {
    unsigned char client;
    unsigned char port;
};

struct snd_seq_ev_note {
    unsigned char channel;
    unsigned char note;
    unsigned char velocity;
    unsigned char off_velocity;
    unsigned int duration;
};

struct snd_seq_ev_ctrl {
    unsigned char channel;
    unsigned char unused[3];
    unsigned int param;
    signed int value;
};

struct snd_seq_ev_raw8 {
    unsigned char d[12];
};

struct snd_seq_ev_raw32 {
    unsigned int d[3];
};

struct snd_seq_ev_ext {
    unsigned int len;
    void *ptr;
} __attribute__((packed));

struct snd_seq_result {
    int event;
    int result;
};

struct snd_seq_real_time {
    unsigned int tv_sec;
    unsigned int tv_nsec;
};

union snd_seq_timestamp {
    snd_seq_tick_time_t tick;
    struct snd_seq_real_time time;
};

struct snd_seq_queue_skew {
    unsigned int value;
    unsigned int base;
};

struct snd_seq_ev_queue_control {
    unsigned char queue;
    unsigned char pad[3];
    union {
        signed int value;
        union snd_seq_timestamp time;
        unsigned int position;
        struct snd_seq_queue_skew skew;
        unsigned int d32[2];
        unsigned char d8[8];
    } param;
};

struct snd_seq_ev_quote {
    struct snd_seq_addr origin;
    unsigned short value;
    struct snd_seq_event *event;
} __attribute__((packed));

struct snd_seq_connect {
    struct snd_seq_addr sender;
    struct snd_seq_addr dest;
};

union snd_seq_event_data {
    struct snd_seq_ev_note note;
    struct snd_seq_ev_ctrl control;
    struct snd_seq_ev_raw8 raw8;
    struct snd_seq_ev_raw32 raw32;
    struct snd_seq_ev_ext ext;
    struct snd_seq_ev_queue_control queue;
    union snd_seq_timestamp time;
    struct snd_seq_addr addr;
    struct snd_seq_connect connect;
    struct snd_seq_result result;
    struct snd_seq_ev_quote quote;
};

struct snd_seq_event {
    snd_seq_event_type_t type;
    unsigned char flags;
    char tag;
    unsigned char queue;
    union snd_seq_timestamp time;
    struct snd_seq_addr source;
    struct snd_seq_addr dest;
    union snd_seq_event_data data;
};

struct snd_seq_client_info {
    int client;
    int type;
    char name[64];
    unsigned int filter;
    unsigned char multicast_filter[8];
    unsigned char event_filter[32];
    int num_ports;
    int event_lost;
    int card;
    int pid;
    unsigned int midi_version;
    unsigned int group_filter;
    char reserved[48];
};

struct snd_seq_port_info {
    struct snd_seq_addr addr;
    char name[64];
    unsigned int capability;
    unsigned int type;
    int midi_channels;
    int midi_voices;
    int synth_voices;
    int read_use;
    int write_use;
    void *kernel;
    unsigned int flags;
    unsigned char time_queue;
    unsigned char direction;
    unsigned char ump_group;
    char reserved[57];
};

struct snd_seq_port_subscribe {
    struct snd_seq_addr sender;
    struct snd_seq_addr dest;
    unsigned int voices;
    unsigned int flags;
    unsigned char queue;
    unsigned char pad[3];
    char reserved[64];
};

#define SNDRV_SEQ_EVENT_NOTEON          6
#define SNDRV_SEQ_EVENT_NOTEOFF         7
#define SNDRV_SEQ_EVENT_CONTROLLER      10
#define SNDRV_SEQ_EVENT_PGMCHANGE       11
#define SNDRV_SEQ_EVENT_PORT_START      63

#define SNDRV_SEQ_PORT_CAP_READ         (1<<0)
#define SNDRV_SEQ_PORT_CAP_WRITE        (1<<1)
#define SNDRV_SEQ_PORT_CAP_SUBS_READ    (1<<5)
#define SNDRV_SEQ_PORT_CAP_SUBS_WRITE   (1<<6)

#define SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC (1<<1)
#define SNDRV_SEQ_PORT_TYPE_APPLICATION (1<<20)

#define SNDRV_SEQ_IOCTL_CLIENT_ID       _IOR ('S', 0x01, int)
#define SNDRV_SEQ_IOCTL_GET_CLIENT_INFO _IOWR('S', 0x10, struct snd_seq_client_info)
#define SNDRV_SEQ_IOCTL_SET_CLIENT_INFO _IOW ('S', 0x11, struct snd_seq_client_info)
#define SNDRV_SEQ_IOCTL_CREATE_PORT     _IOWR('S', 0x20, struct snd_seq_port_info)
#define SNDRV_SEQ_IOCTL_GET_PORT_INFO   _IOWR('S', 0x22, struct snd_seq_port_info)
#define SNDRV_SEQ_IOCTL_SUBSCRIBE_PORT  _IOW ('S', 0x30, struct snd_seq_port_subscribe)
#define SNDRV_SEQ_IOCTL_QUERY_NEXT_CLIENT _IOWR('S', 0x51, struct snd_seq_client_info)
#define SNDRV_SEQ_IOCTL_QUERY_NEXT_PORT _IOWR('S', 0x52, struct snd_seq_port_info)
#define SNDRV_SEQ_PORT_CAP_NO_EXPORT    (1<<7)
#define SNDRV_SEQ_PORT_TYPE_MIDI_GENERIC_ (1<<1)

#endif /* ASEQUENCER_MIN_H */
