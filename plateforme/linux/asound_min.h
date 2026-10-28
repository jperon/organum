#ifndef ASOUND_MIN_H
#define ASOUND_MIN_H

#include <sys/ioctl.h>
#include <sys/types.h>


#define SNDRV_PCM_STREAM_PLAYBACK 0

/* Types */
typedef unsigned long snd_pcm_uframes_t;
typedef signed long snd_pcm_sframes_t;
typedef int snd_pcm_access_t;
typedef int snd_pcm_format_t;
typedef int snd_pcm_state_t;
typedef int snd_pcm_hw_param_t;

/* Formats */
#define SNDRV_PCM_FORMAT_S16_LE ((snd_pcm_format_t) 2)
#define SNDRV_PCM_FORMAT_S32_LE ((snd_pcm_format_t) 10)
#define SNDRV_PCM_FORMAT_FLOAT_LE ((snd_pcm_format_t) 14)

/* Access */
#define SNDRV_PCM_ACCESS_RW_INTERLEAVED ((snd_pcm_access_t) 3)

/* States */
#define SNDRV_PCM_STATE_XRUN ((snd_pcm_state_t) 4)

/* HW params */
#define SNDRV_PCM_HW_PARAM_ACCESS 0
#define SNDRV_PCM_HW_PARAM_FORMAT 1
#define SNDRV_PCM_HW_PARAM_SUBFORMAT 2
#define SNDRV_PCM_HW_PARAM_FIRST_MASK SNDRV_PCM_HW_PARAM_ACCESS
#define SNDRV_PCM_HW_PARAM_LAST_MASK SNDRV_PCM_HW_PARAM_SUBFORMAT
#define SNDRV_PCM_HW_PARAM_SAMPLE_BITS 8
#define SNDRV_PCM_HW_PARAM_FRAME_BITS 9
#define SNDRV_PCM_HW_PARAM_CHANNELS 10
#define SNDRV_PCM_HW_PARAM_RATE 11
#define SNDRV_PCM_HW_PARAM_PERIOD_SIZE 13
#define SNDRV_PCM_HW_PARAM_PERIODS 15
#define SNDRV_PCM_HW_PARAM_BUFFER_SIZE 17
#define SNDRV_PCM_HW_PARAM_FIRST_INTERVAL SNDRV_PCM_HW_PARAM_SAMPLE_BITS
#define SNDRV_PCM_HW_PARAM_LAST_INTERVAL SNDRV_PCM_HW_PARAM_PERIODS

#define SNDRV_MASK_MAX 256

struct snd_mask {
	unsigned int bits[(SNDRV_MASK_MAX + 31) / 32];
};

struct snd_interval {
	unsigned int min, max;
	unsigned int openmin:1,
		     openmax:1,
		     integer:1,
		     empty:1;
};

struct snd_pcm_hw_params {
	unsigned int flags;
	struct snd_mask masks[SNDRV_PCM_HW_PARAM_LAST_MASK -
			       SNDRV_PCM_HW_PARAM_FIRST_MASK + 1];
	struct snd_mask mres[5];
	struct snd_interval intervals[SNDRV_PCM_HW_PARAM_LAST_INTERVAL -
				        SNDRV_PCM_HW_PARAM_FIRST_INTERVAL + 1];
	struct snd_interval ires[9];
	unsigned int rmask;
	unsigned int cmask;
	unsigned int info;
	unsigned int msbits;
	unsigned int rate_num;
	unsigned int rate_den;
	snd_pcm_uframes_t fifo_size;
	unsigned char reserved[64];
};

/* SW params */
struct snd_pcm_sw_params {
	int tstamp_mode;
	unsigned int period_step;
	unsigned int sleep_min;
	snd_pcm_uframes_t avail_min;
	snd_pcm_uframes_t xfer_align;
	snd_pcm_uframes_t start_threshold;
	snd_pcm_uframes_t stop_threshold;
	snd_pcm_uframes_t silence_threshold;
	snd_pcm_uframes_t silence_size;
	snd_pcm_uframes_t boundary;
	unsigned int proto;
	unsigned int tstamp_type;
	unsigned char reserved[56];
};

/* xfer */
struct snd_xferi {
	snd_pcm_sframes_t result;
	void *buf;
	snd_pcm_uframes_t frames;
};

/* status */
typedef int snd_pcm_state_t;
struct timespec;

struct snd_pcm_status {
	snd_pcm_state_t state;
	unsigned char pad1[sizeof(long) - sizeof(int)];
	struct timespec trigger_tstamp;
	struct timespec tstamp;
	snd_pcm_uframes_t appl_ptr;
	snd_pcm_uframes_t hw_ptr;
	snd_pcm_sframes_t delay;
	snd_pcm_uframes_t avail;
	snd_pcm_uframes_t avail_max;
	snd_pcm_uframes_t overrange;
	snd_pcm_state_t suspended_state;
	unsigned int audio_tstamp_data;
	struct timespec audio_tstamp;
	struct timespec driver_tstamp;
	unsigned int audio_tstamp_accuracy;
	unsigned char reserved[52 - 2 * sizeof(struct timespec)];
};

/* ioctls */
#define SNDRV_PCM_IOCTL_HW_REFINE _IOWR('A', 0x10, struct snd_pcm_hw_params)
#define SNDRV_PCM_IOCTL_HW_PARAMS _IOWR('A', 0x11, struct snd_pcm_hw_params)
#define SNDRV_PCM_IOCTL_SW_PARAMS _IOWR('A', 0x13, struct snd_pcm_sw_params)
#define SNDRV_PCM_IOCTL_PREPARE _IO('A', 0x40)
#define SNDRV_PCM_IOCTL_START _IO('A', 0x42)
#define SNDRV_PCM_IOCTL_DROP _IO('A', 0x43)
#define SNDRV_PCM_IOCTL_STATUS _IOR('A', 0x20, struct snd_pcm_status)
#define SNDRV_PCM_IOCTL_WRITEI_FRAMES _IOW('A', 0x50, struct snd_xferi)

#endif /* ASOUND_MIN_H */
