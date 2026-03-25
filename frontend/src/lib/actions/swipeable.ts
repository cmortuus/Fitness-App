/**
 * Svelte action for swipe gestures on set rows.
 * Swipe left → skip, swipe right → delete.
 * No DOM reparenting — works with Svelte's DOM management.
 */

export interface SwipeableOptions {
  onSwipeLeft?: () => void;
  onSwipeRight?: () => void;
  threshold?: number; // pixels, default 60
  disabled?: boolean;
}

export function swipeable(node: HTMLElement, options: SwipeableOptions) {
  let opts = options;
  let startX = 0;
  let startY = 0;
  let currentX = 0;
  let tracking = false;  // we recorded a touchstart
  let swiping = false;   // horizontal swipe confirmed
  let locked = false;     // vertical scroll detected, ignore rest

  function onTouchStart(e: TouchEvent) {
    if (opts.disabled) return;
    // Don't start swipe while keyboard is open (input/select focused)
    const active = document.activeElement;
    if (active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA' || active.tagName === 'SELECT')) return;
    startX = e.touches[0].clientX;
    startY = e.touches[0].clientY;
    currentX = 0;
    tracking = true;
    swiping = false;
    locked = false;
    node.style.transition = 'none';
  }

  function onTouchMove(e: TouchEvent) {
    if (!tracking || opts.disabled || locked) return;

    const dx = e.touches[0].clientX - startX;
    const dy = e.touches[0].clientY - startY;

    // Wait for meaningful movement before deciding direction
    if (!swiping && Math.abs(dx) < 8 && Math.abs(dy) < 8) return;

    if (!swiping) {
      // Vertical wins → lock out, let page scroll normally
      if (Math.abs(dy) > Math.abs(dx)) {
        locked = true;
        return;
      }
      swiping = true;
    }

    e.preventDefault();
    currentX = dx;

    // Visual slide capped at ±120px
    const capped = Math.max(-120, Math.min(120, dx));
    node.style.transform = `translateX(${capped}px)`;

    // Background color tint on the node itself
    const threshold = opts.threshold ?? 60;
    if (dx < -threshold) {
      node.style.background = 'rgba(217,119,6,0.15)';
    } else if (dx > threshold) {
      node.style.background = 'rgba(220,38,38,0.15)';
    } else {
      node.style.background = '';
    }
  }

  function onTouchEnd() {
    if (!swiping) {
      tracking = false;
      return;
    }

    const threshold = opts.threshold ?? 60;

    node.style.transition = 'transform 0.2s ease-out, background 0.2s ease-out';
    node.style.transform = '';
    node.style.background = '';

    if (currentX < -threshold && opts.onSwipeLeft) {
      opts.onSwipeLeft();
    } else if (currentX > threshold && opts.onSwipeRight) {
      opts.onSwipeRight();
    }

    tracking = false;
    swiping = false;
  }

  node.addEventListener('touchstart', onTouchStart, { passive: true });
  node.addEventListener('touchmove', onTouchMove, { passive: false });
  node.addEventListener('touchend', onTouchEnd);

  return {
    update(newOptions: SwipeableOptions) {
      opts = newOptions;
    },
    destroy() {
      node.removeEventListener('touchstart', onTouchStart);
      node.removeEventListener('touchmove', onTouchMove);
      node.removeEventListener('touchend', onTouchEnd);
      node.style.transform = '';
      node.style.transition = '';
      node.style.background = '';
    },
  };
}
