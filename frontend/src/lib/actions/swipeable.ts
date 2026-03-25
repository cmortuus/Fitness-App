/**
 * Svelte action for swipe gestures on set rows.
 * Swipe left → skip, swipe right → delete.
 * Uses touch events with configurable threshold.
 */

export interface SwipeableOptions {
  onSwipeLeft?: () => void;
  onSwipeRight?: () => void;
  threshold?: number; // pixels, default 60
  disabled?: boolean;
}

export function swipeable(node: HTMLElement, options: SwipeableOptions) {
  let opts = options;
  const threshold = opts.threshold ?? 60;
  let startX = 0;
  let startY = 0;
  let currentX = 0;
  let swiping = false;
  let verticalLock = false;

  // Create background elements that show during swipe
  const wrapper = document.createElement('div');
  wrapper.style.cssText = 'position:relative;overflow:hidden;border-radius:0.75rem;';

  const bgSkip = document.createElement('div');
  bgSkip.style.cssText = 'position:absolute;inset:0;display:none;align-items:center;justify-content:flex-end;padding-right:1rem;background:rgba(217,119,6,0.2);border-radius:0.75rem;';
  bgSkip.innerHTML = '<span style="color:#f59e0b;font-size:0.75rem;font-weight:600;">← Skip</span>';

  const bgDelete = document.createElement('div');
  bgDelete.style.cssText = 'position:absolute;inset:0;display:none;align-items:center;justify-content:flex-start;padding-left:1rem;background:rgba(220,38,38,0.2);border-radius:0.75rem;';
  bgDelete.innerHTML = '<span style="color:#f87171;font-size:0.75rem;font-weight:600;">Delete →</span>';

  node.parentNode?.insertBefore(wrapper, node);
  wrapper.appendChild(bgDelete);
  wrapper.appendChild(bgSkip);
  wrapper.appendChild(node);
  node.style.position = 'relative';
  node.style.zIndex = '1';

  function onTouchStart(e: TouchEvent) {
    if (opts.disabled) return;
    // Don't swipe if touching an input, select, or button
    const tag = (e.target as HTMLElement).tagName;
    if (tag === 'INPUT' || tag === 'SELECT' || tag === 'BUTTON') return;

    startX = e.touches[0].clientX;
    startY = e.touches[0].clientY;
    currentX = 0;
    swiping = false;
    verticalLock = false;
    node.style.transition = 'none';
  }

  function onTouchMove(e: TouchEvent) {
    if (opts.disabled || verticalLock) return;
    const dx = e.touches[0].clientX - startX;
    const dy = e.touches[0].clientY - startY;

    // Determine gesture direction on first significant movement
    if (!swiping && Math.abs(dx) < 5 && Math.abs(dy) < 5) return;

    if (!swiping) {
      // If vertical movement dominates, lock out swiping
      if (Math.abs(dy) > Math.abs(dx)) {
        verticalLock = true;
        return;
      }
      swiping = true;
    }

    e.preventDefault();
    currentX = dx;

    // Cap the visual translation
    const capped = Math.max(-120, Math.min(120, dx));
    node.style.transform = `translateX(${capped}px)`;

    bgSkip.style.display = dx < -10 ? 'flex' : 'none';
    bgDelete.style.display = dx > 10 ? 'flex' : 'none';
  }

  function onTouchEnd() {
    if (!swiping) return;

    node.style.transition = 'transform 0.2s ease-out';
    node.style.transform = 'translateX(0)';
    bgSkip.style.display = 'none';
    bgDelete.style.display = 'none';

    if (currentX < -threshold && opts.onSwipeLeft) {
      opts.onSwipeLeft();
    } else if (currentX > threshold && opts.onSwipeRight) {
      opts.onSwipeRight();
    }

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
      // Unwrap
      if (wrapper.parentNode) {
        wrapper.parentNode.insertBefore(node, wrapper);
        wrapper.remove();
      }
      node.style.position = '';
      node.style.zIndex = '';
      node.style.transform = '';
      node.style.transition = '';
    },
  };
}
